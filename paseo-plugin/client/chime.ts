// A soft two-note chime, synthesised once as a WAV, played when an agent newly needs the user.
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function base64(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (i + 1 < bytes.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < bytes.length ? B64[n & 63] : "=");
  }
  return out;
}

function makeChime(): string {
  const rate = 22050;
  const notes = [
    { f: 880, start: 0, len: 0.18 },
    { f: 1318.5, start: 0.14, len: 0.32 },
  ];
  const total = Math.ceil(rate * 0.5);
  const pcm = new Int16Array(total);
  for (const { f, start, len } of notes) {
    const s0 = Math.floor(start * rate);
    const n = Math.floor(len * rate);
    for (let i = 0; i < n && s0 + i < total; i++) {
      const env = Math.min(1, i / (rate * 0.01)) * Math.exp((-4 * i) / n); // quick attack, soft decay
      pcm[s0 + i] += Math.round(Math.sin((2 * Math.PI * f * i) / rate) * env * 9000);
    }
  }
  const buf = new Uint8Array(44 + total * 2);
  const v = new DataView(buf.buffer);
  const str = (o: number, t: string) => [...t].forEach((ch, i) => v.setUint8(o + i, ch.charCodeAt(0)));
  str(0, "RIFF"); v.setUint32(4, 36 + total * 2, true); str(8, "WAVE");
  str(12, "fmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, "data"); v.setUint32(40, total * 2, true);
  for (let i = 0; i < total; i++) v.setInt16(44 + i * 2, pcm[i], true);
  return base64(buf);
}

type Player = (source: { base64: string; mimeType: string }) => Promise<void>;
let player: Player | null = null;
let chime: string | null = null;
let seen: Set<string> | null = null;

export function setPlayer(play: Player) {
  player = play;
}

// Chimes once for each need not seen before. The first call only records what is already open.
export function chimeForNew(keys: string[]) {
  if (!seen) {
    seen = new Set(keys);
    return;
  }
  const fresh = keys.filter((k) => !seen!.has(k));
  seen = new Set(keys);
  if (fresh.length && player) {
    chime ??= makeChime();
    void player({ base64: chime, mimeType: "audio/wav" }).catch(() => {});
  }
}
