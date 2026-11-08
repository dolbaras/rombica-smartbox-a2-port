import android.media.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.util.*;

// Decoder probe for the RustDesk mediacodec path: ByteBuffer output, no Surface.
// usage: McTest list
//        McTest <file.mp4> <codec> <rustdesk|real|fixed> <fps|0> <idx|now>[+csd] [option ...]
//   rustdesk  configure 0x0 + color-format 19 (what upstream mediacodec.rs did)
//   real      the stream size; fixed: 1920x1080
//   fps       feed rate, 0 = as fast as possible
//   idx|now   presentation times: frame index or clock; +csd: SPS/PPS in the format, not in frame 0
//   options   key=int (MediaFormat, e.g. vendor.low-latency.enable=1), size=WxH, dump=N
//             (frame N -> /data/local/tmp/mct/frame.yuv), limit=N (feed only N frames)
public class McTest {
    static void list() {
        for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (ci.isEncoder()) continue;
            for (String t : ci.getSupportedTypes()) {
                if (!t.equals("video/avc") && !t.equals("video/hevc")) continue;
                MediaCodecInfo.CodecCapabilities cc = ci.getCapabilitiesForType(t);
                System.out.println(ci.getName() + " " + t + " colorFormats=" + Arrays.toString(cc.colorFormats));
            }
        }
    }

    public static void main(String[] a) throws Exception {
        if (a[0].equals("list")) { list(); return; }
        String file = a[0], name = a[1];
        boolean rd = a[2].equals("rustdesk");
        int dump = -1, limit = 0;
        int fps = Integer.parseInt(a[3]);
        boolean ptsNow = a[4].startsWith("now");
        boolean csdFmt = a[4].endsWith("+csd");

        MediaExtractor ex = new MediaExtractor();
        ex.setDataSource(file);
        ex.selectTrack(0);
        MediaFormat src = ex.getTrackFormat(0);
        String mime = src.getString(MediaFormat.KEY_MIME);
        // RustDesk sends Annex-B frames with the parameter sets inline in the key frame
        ByteArrayOutputStream csd = new ByteArrayOutputStream();
        for (String k : new String[]{"csd-0", "csd-1"}) {
            if (!src.containsKey(k)) continue;
            ByteBuffer b = src.getByteBuffer(k).duplicate();
            byte[] x = new byte[b.remaining()]; b.get(x); csd.write(x);
        }
        List<byte[]> frames = new ArrayList<>();
        ByteBuffer sb = ByteBuffer.allocate(4 << 20);
        while (true) {
            int n = ex.readSampleData(sb, 0);
            if (n < 0) break;
            byte[] x = new byte[n]; sb.position(0); sb.get(x, 0, n);
            if (frames.isEmpty() && !csdFmt) { csd.write(x); x = csd.toByteArray(); }
            frames.add(x); ex.advance();
        }
        System.out.println("frames=" + frames.size() + " mime=" + mime);

        int N = limit > 0 ? limit : frames.size();
        MediaCodec c = MediaCodec.createByCodecName(name);
        boolean fixed = a[2].equals("fixed");
        MediaFormat f = MediaFormat.createVideoFormat(mime, rd ? 0 : fixed ? 1920 : src.getInteger("width"), rd ? 0 : fixed ? 1080 : src.getInteger("height"));
        if (rd) f.setInteger(MediaFormat.KEY_COLOR_FORMAT, 19); // as RustDesk mediacodec.rs
        if (csdFmt) for (String k : new String[]{"csd-0", "csd-1"}) if (src.containsKey(k)) f.setByteBuffer(k, src.getByteBuffer(k));
        for (int i = 5; i < a.length; i++) {
            String[] kv = a[i].split("=");
            if (kv[0].equals("dump")) { dump = Integer.parseInt(kv[1]); continue; }
            if (kv[0].equals("limit")) { limit = Integer.parseInt(kv[1]); continue; }
            if (kv[0].equals("size")) { String[] wh = kv[1].split("x"); f.setInteger("width", Integer.parseInt(wh[0])); f.setInteger("height", Integer.parseInt(wh[1])); continue; }
            f.setInteger(kv[0], Integer.parseInt(kv[1]));
        }
        if (limit > 0) N = limit;
        try {
            c.configure(f, null, null, 0);
        } catch (Exception e) {
            System.out.println("CONFIGURE FAILED: " + e);
            c.release();
            return;
        }
        c.start();

        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
        long[] tin = new long[N];
        Map<Long, Integer> byPts = new HashMap<>();
        long lat = 0, latMax = 0, t0 = System.nanoTime(), lastOut = t0;
        int out = 0, in = 0, inflightMax = 0;
        while (out < N) {
            long now = System.nanoTime();
            boolean due = fps == 0 || now - t0 >= (long) in * 1_000_000_000L / fps;
            if (in < N && due) {
                int ii = c.dequeueInputBuffer(2000);
                if (ii >= 0) {
                    byte[] x = frames.get(in);
                    ByteBuffer ib = c.getInputBuffer(ii);
                    ib.clear(); ib.put(x);
                    long pts = ptsNow ? System.nanoTime() / 1000 : in * 33333L;
                    byPts.put(pts, in);
                    tin[in] = System.nanoTime();
                    c.queueInputBuffer(ii, 0, x.length, pts, 0);
                    in++;
                }
            }
            inflightMax = Math.max(inflightMax, in - out);
            int oi = c.dequeueOutputBuffer(bi, 2000);
            if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat of = c.getOutputFormat();
                System.out.println("format: " + of); System.out.println("output: color-format=" + of.getInteger("color-format") + " " + of.getInteger("width") + "x" + of.getInteger("height")
                        + " stride=" + of.getInteger("stride") + " slice-height=" + of.getInteger("slice-height"));
            } else if (oi >= 0) {
                Integer idx = byPts.get(bi.presentationTimeUs);
                long t = System.nanoTime();
                long l = idx == null ? 0 : t - tin[idx];
                lat += l; latMax = Math.max(latMax, l);
                if (out < 5) System.out.printf("out %d: frame %s size %d latency %.1f ms%n", out, idx, bi.size, l / 1e6);
                ByteBuffer ob = c.getOutputBuffer(oi);
                if (out == dump) {
                    byte[] x = new byte[bi.size]; ob.position(bi.offset); ob.get(x);
                    try (FileOutputStream fo = new FileOutputStream("/data/local/tmp/mct/frame.yuv")) { fo.write(x); }
                    System.out.println("dumped frame " + idx + " (" + x.length + " bytes)");
                }
                c.releaseOutputBuffer(oi, false);
                out++; lastOut = t;
            } else if (System.nanoTime() - lastOut > 5_000_000_000L) {
                System.out.println("STALL: no output for 5 s, in=" + in + " out=" + out);
                break;
            }
        }
        double s = (lastOut - t0) / 1e9;
        System.out.printf("decoded %d/%d in %.2fs = %.1f fps; latency avg %.1f ms max %.1f ms; frames in flight max %d%n",
                out, N, s, out / s, out > 0 ? lat / 1e6 / out : 0, latMax / 1e6, inflightMax);
        c.stop(); c.release();
    }
}
