package ru.rombica.codectest;

import android.app.Activity;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import java.nio.ByteBuffer;

/**
 * am start -W -n ru.rombica.codectest/.TestActivity --es file /sdcard/x.webm [--es codec NAME]
 *   [--es list 1]
 * Decodes the first video (else audio) track as fast as possible; video frames are rendered to
 * a full-screen SurfaceView. Logs one "RESULT ..." line with tag CODECTEST.
 *
 * am start -n ru.rombica.codectest/.TestActivity --es audiorate SECONDS
 * Plays a 1 kHz tone (48 kHz stereo) and measures the rate at which the audio hardware consumes
 * frames (AudioTrack playback head vs. elapsedRealtime): 48000 means the output clock is right.
 */
public class TestActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "CODECTEST";
    private SurfaceView mView;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        if (getIntent().getStringExtra("list") != null) {
            for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
                if (ci.isEncoder()) continue;
                for (String t : ci.getSupportedTypes()) Log.i(TAG, "CODEC " + ci.getName() + " " + t);
            }
            finish();
            return;
        }
        final String rate = getIntent().getStringExtra("audiorate");
        if (rate != null) {
            new Thread(new Runnable() {
                @Override public void run() {
                    Log.i(TAG, "RESULT audiorate " + audioRate(Integer.parseInt(rate)));
                    finish();
                }
            }).start();
            return;
        }
        mView = new SurfaceView(this);
        mView.getHolder().addCallback(this);
        setContentView(mView);
    }

    @Override public void surfaceCreated(final SurfaceHolder h) {
        final String file = getIntent().getStringExtra("file");
        final String codec = getIntent().getStringExtra("codec");
        new Thread(new Runnable() {
            @Override public void run() {
                String r;
                try {
                    r = decode(file, codec, h.getSurface());
                } catch (Throwable t) {
                    r = "FAIL " + t.getClass().getSimpleName() + ": " + t.getMessage();
                }
                Log.i(TAG, "RESULT " + file + " " + r);
                finish();
            }
        }).start();
    }
    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) {}
    @Override public void surfaceDestroyed(SurfaceHolder h) {}

    private static String audioRate(int seconds) {
        final int sr = 48000;
        int min = AudioTrack.getMinBufferSize(sr, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT);
        AudioTrack t = new AudioTrack(AudioManager.STREAM_MUSIC, sr, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT, min * 4, AudioTrack.MODE_STREAM);
        short[] buf = new short[sr / 10 * 2];
        long written = 0;
        t.play();
        long start = SystemClock.elapsedRealtime(), t0 = 0, t1 = 0;
        long p0 = -1, p1 = 0;
        while (SystemClock.elapsedRealtime() - start < (seconds + 3) * 1000L) {
            for (int i = 0; i < buf.length / 2; i++) {
                short v = (short) (8000 * Math.sin(2 * Math.PI * 1000 * (written + i) / sr));
                buf[2 * i] = v; buf[2 * i + 1] = v;
            }
            t.write(buf, 0, buf.length);
            written += buf.length / 2;
            long now = SystemClock.elapsedRealtimeNanos();
            if (p0 < 0 && now / 1000000 - start > 3000) {    // skip start-up
                p0 = t.getPlaybackHeadPosition() & 0xffffffffL; t0 = now;
            } else if (p0 >= 0) {
                p1 = t.getPlaybackHeadPosition() & 0xffffffffL; t1 = now;
            }
        }
        t.stop(); t.release();
        double r = (p1 - p0) / ((t1 - t0) / 1e9);
        return String.format("%.1f frames/s = x%.4f of %d (%.1f s)", r, r / sr, sr, (t1 - t0) / 1e9);
    }

    private static String decode(String file, String codecName, Surface surface) throws Exception {
        MediaExtractor ex = new MediaExtractor();
        ex.setDataSource(file);
        int track = -1;
        for (int i = 0; i < ex.getTrackCount(); i++) {
            String m = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
            if (m.startsWith("video/")) { track = i; break; }
            if (m.startsWith("audio/") && track < 0) track = i;
        }
        if (track < 0) return "FAIL no track";
        ex.selectTrack(track);
        MediaFormat fmt = ex.getTrackFormat(track);
        String mime = fmt.getString(MediaFormat.KEY_MIME);
        boolean video = mime.startsWith("video/");
        if (codecName == null)
            codecName = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(fmt);
        if (codecName == null) return "FAIL mime=" + mime + " no decoder";
        MediaCodec c = MediaCodec.createByCodecName(codecName);
        c.configure(fmt, video ? surface : null, null, 0);
        c.start();
        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
        int in = 0, out = 0; boolean eosIn = false; long t0 = System.nanoTime(), nonzero = 0;
        long deadline = t0 + 60_000_000_000L;
        while (System.nanoTime() < deadline) {
            if (!eosIn) {
                int ii = c.dequeueInputBuffer(10000);
                if (ii >= 0) {
                    ByteBuffer buf = c.getInputBuffer(ii);
                    int n = ex.readSampleData(buf, 0);
                    if (n < 0) {
                        c.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                        eosIn = true;
                    } else {
                        c.queueInputBuffer(ii, 0, n, ex.getSampleTime(), 0);
                        ex.advance(); in++;
                    }
                }
            }
            int oi = c.dequeueOutputBuffer(bi, 10000);
            if (oi >= 0) {
                if (bi.size > 0 || video) out++;
                if (!video && bi.size > 0) {
                    ByteBuffer ob = c.getOutputBuffer(oi);
                    for (int k = 0; k < bi.size; k += 64) if (ob.get(bi.offset + k) != 0) { nonzero++; break; }
                }
                c.releaseOutputBuffer(oi, video);
                if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
            }
        }
        double s = (System.nanoTime() - t0) / 1e9;
        MediaFormat of = c.getOutputFormat();
        c.stop(); c.release(); ex.release();
        String info = video ? (of.getInteger(MediaFormat.KEY_WIDTH) + "x" + of.getInteger(MediaFormat.KEY_HEIGHT))
                : (of.getInteger(MediaFormat.KEY_SAMPLE_RATE) + "Hz/" + of.getInteger(MediaFormat.KEY_CHANNEL_COUNT) + "ch nonzero=" + nonzero);
        return String.format("OK codec=%s mime=%s in=%d out=%d %s time=%.2fs fps=%.1f",
                codecName, mime, in, out, info, s, out / s);
    }
}
