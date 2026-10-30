const $ = (id) => document.getElementById(id);

async function currentTab() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  return tab;
}

(async () => {
  const tab = await currentTab();
  let host = "";
  try { host = new URL(tab.url).hostname.toLowerCase().replace(/^www\./, ""); } catch (e) {}
  const settings = await browser.storage.local.get(["enabled", "excluded"]);
  const excluded = settings.excluded || [];
  $("enabled").checked = settings.enabled !== false;
  if (!host) {
    $("site-section").hidden = true;
  } else {
    $("host").textContent = host;
    $("excluded").checked = excluded.includes(host);
  }

  $("enabled").addEventListener("change", (e) => browser.storage.local.set({ enabled: e.target.checked }));
  $("excluded").addEventListener("change", async (e) => {
    const list = ((await browser.storage.local.get("excluded")).excluded || []).filter((s) => s !== host);
    if (e.target.checked) list.push(host);
    await browser.storage.local.set({ excluded: list });
  });
  $("stay").addEventListener("click", async () => {
    await browser.storage.local.set({ stayOnce: { host: new URL(tab.url).hostname.toLowerCase(), at: Date.now() } });
    window.close();
  });
  $("open").addEventListener("click", async () => {
    await browser.tabs.update(tab.id, { url: "firefoxgecko://open-url?url=" + encodeURIComponent(tab.url) });
    window.close();
  });
})();
