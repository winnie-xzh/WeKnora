const { getSettings, saveSettings } = require("../../utils/config");
const { listAgents } = require("../../utils/request");

function normalizeAgents(response) {
  if (Array.isArray(response && response.data)) return response.data;
  if (Array.isArray(response)) return response;
  return [];
}

Page({
  data: {
    baseUrl: "",
    apiKey: "",
    agentId: "",
    agentEnabled: false,
    webSearchEnabled: false,
    agents: [],
    agentNames: [],
    agentIndex: 0,
    sidebarOpen: false,
    activeKey: "settings",
    navbarHeight: 0
  },

  onLoad() {
    var sysInfo = wx.getSystemInfoSync();
    this.setData({ navbarHeight: sysInfo.statusBarHeight + 44 });
  },

  onShow() {
    var settings = getSettings();
    this.setData({
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      agentId: settings.agentId,
      agentEnabled: settings.agentEnabled,
      webSearchEnabled: settings.webSearchEnabled
    });
    this.loadAgents();
  },

  onMenuTap() { this.setData({ sidebarOpen: true }); },
  onSidebarClose() { this.setData({ sidebarOpen: false }); },
  onSidebarItemTap(e) {
    var pageMap = { knowledge: "index", chat: "chat", settings: "settings" };
    this.setData({ sidebarOpen: false });
    wx.redirectTo({ url: "/pages/" + pageMap[e.detail.key] + "/" + pageMap[e.detail.key] });
  },

  onBaseUrlInput(e) { this.setData({ baseUrl: e.detail.value }); },
  onApiKeyInput(e) { this.setData({ apiKey: e.detail.value }); },

  onAgentChange(e) {
    var idx = Number(e.detail.value);
    var selected = this.data.agents[idx];
    this.setData({ agentIndex: idx, agentId: selected ? selected.id : "" });
  },

  onAgentToggle() { this.setData({ agentEnabled: !this.data.agentEnabled }); },
  onWebSearchToggle() { this.setData({ webSearchEnabled: !this.data.webSearchEnabled }); },

  async loadAgents() {
    var settings = getSettings();
    if (!settings.baseUrl || !settings.apiKey) return;
    try {
      var response = await listAgents();
      var agents = normalizeAgents(response);
      var agentNames = agents.map(function(item) { return item.name || item.id; });
      var currentId = this.data.agentId || settings.agentId || "";
      var agentIndex = Math.max(0, agents.findIndex(function(item) { return item.id === currentId; }));
      this.setData({ agents: agents, agentNames: agentNames, agentIndex: agentIndex });
    } catch (e) {}
  },

  save() {
    saveSettings({
      baseUrl: this.data.baseUrl,
      apiKey: this.data.apiKey,
      agentId: this.data.agentId,
      agentEnabled: this.data.agentEnabled,
      webSearchEnabled: this.data.webSearchEnabled
    });
    wx.showToast({ title: "Saved", icon: "success" });
  }
});
