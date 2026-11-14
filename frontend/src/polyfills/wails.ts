declare global {
  interface Window {
    _wails?: any;
  }
}

(() => {
  const w = (window as any)._wails || {};
  w.environment = w.environment || {};
  if (typeof w.environment.OS !== "string") {
    const ua = String(navigator.userAgent || "").toLowerCase();
    const plat = String((navigator as any).platform || "");
    const isWin = ua.includes("windows") || plat.startsWith("Win");
    w.environment.OS = isWin ? "windows" : "unknown";
  }
  (window as any)._wails = w;
})();

export {};
