/** Optional, self-reported display metadata; never an authentication factor. */
export function normalizeDeviceInfo(input) {
  const value = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const text = (key, max) => typeof value[key] === "string"
    ? value[key].replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "").trim().slice(0, max) : "";
  const clientId = text("clientId", 81);
  return {
    clientId: /^[A-Za-z0-9_-]{8,80}$/.test(clientId) ? clientId : "",
    deviceName: text("deviceName", 80),
    platform: text("platform", 32),
    osVersion: text("osVersion", 40),
    appVersion: text("appVersion", 40),
  };
}

export const isNativeApp = (ua) => /DSHRemotePortal\/|YuRemote\//i.test(String(ua || ""));
