import assert from "node:assert/strict";
import { runInNewContext } from "node:vm";

// Exercise the actual response scripts without a browser or DOM dependency.
// Layout, system-color resolution and keyboard use are browser checks.
export function exercisePageTheme(html) {
  function boot(saved, blocked = false) {
    const attributes = new Map([["data-theme", html.match(/<html[^>]*data-theme="([^"]+)"/)?.[1]]]);
    const root = {
      classList: { add() {}, remove() {} },
      setAttribute: (key, value) => attributes.set(key, value),
      getAttribute: key => attributes.get(key),
    };
    const events = {};
    const button = { setAttribute() {}, addEventListener: (name, callback) => { events[name] = callback; } };
    const meta = { setAttribute() {} };
    let ready;
    let preference = saved;
    const document = {
      documentElement: root,
      getElementById: id => id === "yuremote-theme-btn" ? button : /^(?:yuremote-meta-|theme-)/.test(id) ? meta : null,
      addEventListener: (name, callback) => { if (name === "DOMContentLoaded") ready = callback; },
    };
    const localStorage = {
      getItem(key) { assert.equal(key, "yuremote-theme"); if (blocked) throw Error("Storage denied"); return preference; },
      setItem(key, value) { assert.equal(key, "yuremote-theme"); if (blocked) throw Error("Storage denied"); preference = value; },
    };
    const context = { document, localStorage };
    for (const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) runInNewContext(script[1], context);
    ready?.();
    return { theme: () => root.getAttribute("data-theme"), click: () => events.click(), saved: () => preference };
  }
  const first = boot(null);
  assert.equal(first.theme(), "auto", "a fresh visit must follow the system");
  assert.equal(first.saved(), null, "a fresh visit must not pin an OS color");
  first.click();
  assert.equal(first.theme(), "light");
  assert.equal(first.saved(), "light");
  const reload = boot(first.saved());
  assert.equal(reload.theme(), "light", "reload must restore the explicit choice");
  reload.click();
  assert.equal(reload.theme(), "dark");
  assert.equal(boot(reload.saved()).theme(), "dark");
  reload.click();
  assert.equal(reload.theme(), "auto");
  assert.equal(boot(reload.saved()).theme(), "auto");
  assert.equal(boot("invalid-theme").theme(), "auto");
  const denied = boot(null, true);
  assert.equal(denied.theme(), "auto");
  denied.click();
  assert.equal(denied.theme(), "light", "denied storage must not break the toggle");
}
