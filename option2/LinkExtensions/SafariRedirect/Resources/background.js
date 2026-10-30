browser.runtime.onMessage.addListener((message, sender) => {
  if (message && message.type === "close" && sender.tab && sender.tab.id !== undefined) {
    return browser.tabs.remove(sender.tab.id).catch(() => {});
  }
});
