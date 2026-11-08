import android.graphics.SurfaceTexture;
import android.media.*;
import android.opengl.*;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import java.io.*;
import java.nio.*;
import java.util.*;

// Decode into a SurfaceTexture (the way a Flutter Texture is fed) and read one frame back with GL.
// usage: McSurf <file.mp4> <codec> <fps> <dumpFrame> [key=int ...]
public class McSurf {
    static final String VS = "attribute vec4 p; attribute vec2 t; varying vec2 v; uniform mat4 m;"
            + "void main(){ gl_Position = p; v = (m * vec4(t, 0.0, 1.0)).xy; }";
    static final String FS = "#extension GL_OES_EGL_image_external : require\n"
            + "precision mediump float; varying vec2 v; uniform samplerExternalOES s;"
            + "void main(){ gl_FragColor = texture2D(s, v); }";

    static volatile int available = 0;

    public static void main(String[] a) throws Exception {
        String file = a[0], name = a[1];
        int fps = Integer.parseInt(a[2]), dump = Integer.parseInt(a[3]);

        // offscreen GL context
        EGLDisplay dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] ver = new int[2];
        EGL14.eglInitialize(dpy, ver, 0, ver, 1);
        EGLConfig[] cfg = new EGLConfig[1];
        int[] n = new int[1];
        EGL14.eglChooseConfig(dpy, new int[]{EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE}, 0, cfg, 0, 1, n, 0);
        EGLContext ctx = EGL14.eglCreateContext(dpy, cfg[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
        EGLSurface pb = EGL14.eglCreatePbufferSurface(dpy, cfg[0], new int[]{EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE}, 0);
        EGL14.eglMakeCurrent(dpy, pb, pb, ctx);

        int[] tex = new int[1];
        GLES20.glGenTextures(1, tex, 0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex[0]);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        SurfaceTexture st = new SurfaceTexture(tex[0]);
        HandlerThread ht = new HandlerThread("st");
        ht.start();
        st.setOnFrameAvailableListener(new SurfaceTexture.OnFrameAvailableListener() { public void onFrameAvailable(SurfaceTexture s) { available++; } }, new Handler(ht.getLooper()));
        Surface surface = new Surface(st);

        MediaExtractor ex = new MediaExtractor();
        ex.setDataSource(file);
        ex.selectTrack(0);
        MediaFormat src = ex.getTrackFormat(0);
        String mime = src.getString(MediaFormat.KEY_MIME);
        int w = src.getInteger("width"), h = src.getInteger("height");
        ByteArrayOutputStream csd = new ByteArrayOutputStream();
        for (String k : new String[]{"csd-0", "csd-1"}) {
            if (!src.containsKey(k)) continue;
            ByteBuffer b = src.getByteBuffer(k).duplicate();
            byte[] x = new byte[b.remaining()]; b.get(x); csd.write(x);
        }
        List<byte[]> frames = new ArrayList<>();
        ByteBuffer sb = ByteBuffer.allocate(4 << 20);
        while (true) {
            int len = ex.readSampleData(sb, 0);
            if (len < 0) break;
            byte[] x = new byte[len]; sb.position(0); sb.get(x, 0, len);
            if (frames.isEmpty()) { csd.write(x); x = csd.toByteArray(); }
            frames.add(x); ex.advance();
        }
        int N = frames.size();

        MediaCodec c = MediaCodec.createByCodecName(name);
        MediaFormat f = MediaFormat.createVideoFormat(mime, w, h);
        for (int i = 4; i < a.length; i++) {
            String[] kv = a[i].split("=");
            f.setInteger(kv[0], Integer.parseInt(kv[1]));
        }
        c.configure(f, surface, null, 0);
        c.start();
        System.out.println("started " + name + " " + w + "x" + h + " frames=" + N);

        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
        long[] tin = new long[N];
        long t0 = System.nanoTime(), lat = 0, latMax = 0, lastOut = t0;
        int in = 0, out = 0, latched = 0;
        while (out < N) {
            long now = System.nanoTime();
            if (in < N && now - t0 >= (long) in * 1_000_000_000L / fps) {
                int ii = c.dequeueInputBuffer(2000);
                if (ii >= 0) {
                    byte[] x = frames.get(in);
                    ByteBuffer ib = c.getInputBuffer(ii);
                    ib.clear(); ib.put(x);
                    tin[in] = System.nanoTime();
                    c.queueInputBuffer(ii, 0, x.length, in * 33333L, 0);
                    in++;
                }
            }
            int oi = c.dequeueOutputBuffer(bi, 2000);
            if (oi >= 0) {
                int idx = (int) (bi.presentationTimeUs / 33333L);
                c.releaseOutputBuffer(oi, true);
                long l = System.nanoTime() - tin[Math.min(idx, N - 1)];
                lat += l; latMax = Math.max(latMax, l);
                out++; lastOut = System.nanoTime();
            } else if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                System.out.println("output format: " + c.getOutputFormat());
            } else if (System.nanoTime() - lastOut > 5_000_000_000L) {
                System.out.println("STALL: in=" + in + " out=" + out);
                break;
            }
            if (available > latched) {
                st.updateTexImage();
                latched++;
                if (latched == dump) readBack(st, tex[0], w, h);
            }
        }
        Thread.sleep(200);
        while (available > latched) { st.updateTexImage(); latched++; }
        double s = (lastOut - t0) / 1e9;
        System.out.printf("rendered %d/%d in %.2fs = %.1f fps; frames on texture %d; latency avg %.1f ms max %.1f ms%n",
                out, N, s, out / s, latched, out > 0 ? lat / 1e6 / out : 0, latMax / 1e6);
        c.stop(); c.release();
        surface.release(); st.release();
        ht.quit();
    }

    // draw the external texture into an FBO of the video size and save the RGBA pixels
    static void readBack(SurfaceTexture st, int tex, int w, int h) throws IOException {
        int[] fb = new int[1], rb = new int[1];
        GLES20.glGenTextures(1, rb, 0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, rb[0]);
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);
        GLES20.glGenFramebuffers(1, fb, 0);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fb[0]);
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, rb[0], 0);
        int prog = GLES20.glCreateProgram();
        for (int[] sh : new int[][]{{GLES20.GL_VERTEX_SHADER, 0}, {GLES20.GL_FRAGMENT_SHADER, 1}}) {
            int s = GLES20.glCreateShader(sh[0]);
            GLES20.glShaderSource(s, sh[1] == 0 ? VS : FS);
            GLES20.glCompileShader(s);
            GLES20.glAttachShader(prog, s);
        }
        GLES20.glLinkProgram(prog);
        GLES20.glUseProgram(prog);
        float[] m = new float[16];
        st.getTransformMatrix(m);
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(prog, "m"), 1, false, m, 0);
        FloatBuffer pos = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().put(new float[]{-1, -1, 1, -1, -1, 1, 1, 1});
        FloatBuffer uv = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().put(new float[]{0, 0, 1, 0, 0, 1, 1, 1});
        pos.position(0); uv.position(0);
        int pl = GLES20.glGetAttribLocation(prog, "p"), tl = GLES20.glGetAttribLocation(prog, "t");
        GLES20.glEnableVertexAttribArray(pl);
        GLES20.glVertexAttribPointer(pl, 2, GLES20.GL_FLOAT, false, 0, pos);
        GLES20.glEnableVertexAttribArray(tl);
        GLES20.glVertexAttribPointer(tl, 2, GLES20.GL_FLOAT, false, 0, uv);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex);
        GLES20.glViewport(0, 0, w, h);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        ByteBuffer px = ByteBuffer.allocateDirect(w * h * 4);
        GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, px);
        byte[] x = new byte[w * h * 4];
        px.get(x);
        try (FileOutputStream fo = new FileOutputStream("/data/local/tmp/mct/frame.rgba")) { fo.write(x); }
        System.out.println("read back frame: GL error " + GLES20.glGetError());
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
    }
}
