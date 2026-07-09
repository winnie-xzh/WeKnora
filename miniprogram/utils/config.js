var STORAGE_KEY = "weknora_settings";

var DEFAULTS = {
  baseUrl: "https://ai.gxlyykt.cn",
  apiKey: "sk-vXIB3UGO5kUbDSqQMyZJTN07_PBTVMx0J4m7uuc3LRksOSEW",
  selectedKnowledgeBaseId: "",
  agentId: "builtin-quick-answer",
  agentEnabled: true,
  webSearchEnabled: true
};

function normalizeBaseUrl(baseUrl) {
  if (!baseUrl || typeof baseUrl !== "string") return "";
  return baseUrl.trim().replace(/\/+$/, "");
}

function getSettings() {
  return {
    baseUrl: normalizeBaseUrl(DEFAULTS.baseUrl),
    apiKey: DEFAULTS.apiKey,
    selectedKnowledgeBaseId: DEFAULTS.selectedKnowledgeBaseId || "",
    agentId: DEFAULTS.agentId || "",
    agentEnabled: true,
    webSearchEnabled: true
  };
}

function saveSettings(settings) {
  return getSettings();
}

module.exports = {
  STORAGE_KEY: STORAGE_KEY,
  getSettings: getSettings,
  normalizeBaseUrl: normalizeBaseUrl,
  saveSettings: saveSettings
};
