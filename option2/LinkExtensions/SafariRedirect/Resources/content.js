// Runs before the page loads: hand the URL to Firefox Gecko unless the user
// turned redirecting off, excluded this site, or asked to stay once.
(async () => {
  if (window.top !== window) return;
  const href = location.href;
  if (!/^https?:/i.test(href)) return;
  const host = location.hostname.toLowerCase();
  let settings;
  try {
    settings = await browser.storage.local.get(["enabled", "excluded", "stayOnce"]);
  } catch (e) {
    return;
  }
  if (settings.enabled === false) return;
  if ((settings.excluded || []).some((site) => host === site || host.endsWith("." + site))) return;
  if (settings.stayOnce && settings.stayOnce.host === host && Date.now() - settings.stayOnce.at < 10 * 60 * 1000) return;

  const root = document.documentElement;
  if (root) root.style.visibility = "hidden";
  const restore = setTimeout(() => { if (root) root.style.visibility = ""; }, 3000);

  // Once Firefox Gecko is in front, the Safari tab has done its job.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      clearTimeout(restore);
      browser.runtime.sendMessage({ type: "close" }).catch(() => {});
    }
  });
  location.replace("firefoxgecko://open-url?url=" + encodeURIComponent(href));
})();
