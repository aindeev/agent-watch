export function ago(ms: number): string {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 90) return `${Math.round(s)}s ago`;
  if (s < 5400) return `${Math.round(s / 60)}m ago`;
  return `${(s / 3600).toFixed(1)}h ago`;
}

export function clock(ms: number): string {
  const d = new Date(ms);
  const h = d.getHours();
  return `${((h + 11) % 12) + 1}:${String(d.getMinutes()).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
}

// "Calling you in 4m" / "Call held until 8:00 AM" for a need, from the watcher's estimate.
export function callWhen(need: { callAt: number | null; held: boolean }): string {
  if (need.callAt == null) return "No more calls about this one (no answer after 3 tries).";
  const ms = need.callAt * 1000;
  if (need.held) return `Call held until ${clock(ms)}`;
  const min = Math.round((ms - Date.now()) / 60_000);
  return min <= 0 ? "Calling you about this now" : `Calling you in ${min}m unless you answer here`;
}
