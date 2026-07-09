const { getSettings } = require("../../utils/config");
const { createSession, knowledgeChatStream, getSuggestedQuestions } = require("../../utils/request");
const { markdownToHtml } = require("../../utils/markdown");

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "<br/>");
}

Page({
  data: {
    messages: [], loading: false, query: "",
    sidebarOpen: false, activeKey: "chat", navbarHeight: 0,
    suggestions: []
  },

  streamController: null,

  onLoad() {
    var sysInfo = wx.getSystemInfoSync();
    this.setData({ navbarHeight: sysInfo.statusBarHeight + 44 });
  },

  onShow() {
    this.loadSuggestions();
  },

  onQueryInput(e) { this.setData({ query: e.detail.value }); },
  onMenuTap() { this.setData({ sidebarOpen: true }); },
  onSidebarClose() { this.setData({ sidebarOpen: false }); },

  onSidebarItemTap(e) {
    var pageMap = { knowledge: "index", chat: "chat", settings: "settings" };
    this.setData({ sidebarOpen: false });
    wx.redirectTo({ url: "/pages/" + pageMap[e.detail.key] + "/" + pageMap[e.detail.key] });
  },

  async loadSuggestions() {
    var settings = getSettings();
    if (!settings.agentId) return;
    try {
      var resp = await getSuggestedQuestions(settings.agentId, settings.selectedKnowledgeBaseId, 6);
      var items = [];
      if (resp && resp.data && resp.data.questions && Array.isArray(resp.data.questions)) {
        items = resp.data.questions.map(function(q) { return q.question; });
      }
      this.setData({ suggestions: items });
    } catch (e) {
      this.setData({ suggestions: [] });
    }
  },

  onSuggestionTap(e) {
    var text = e.currentTarget.dataset.text;
    this.setData({ query: text });
    this.doSend(text);
  },

  async ensureSession() {
    if (this._sessionId) return this._sessionId;
    var response = await createSession(getSettings().selectedKnowledgeBaseId, getSettings().agentId);
    var sessionId = response.data && response.data.id;
    if (!sessionId) throw new Error("The session API did not return a session id.");
    this._sessionId = sessionId;
    return sessionId;
  },

  onUnload() { if (this.streamController) { this.streamController.abort(); this.streamController = null; } },

  // Called from send button (no args, uses this.data.query)
  ask() {
    this.doSend(this.data.query);
  },

  async doSend(text) {
    var query = (text || "").trim();
    if (!query) return;
    var self = this;
    var settings = getSettings();
    var messages = this.data.messages.concat([{ role: "user", content: query, html: escapeHtml(query) }]);
    this.setData({ messages: messages, query: "", loading: true });

    try {
      var sessionId = await this.ensureSession();
      var assistantMsg = { role: "assistant", content: "", html: "", thinking: "", thinkingDone: false };
      messages = messages.concat([assistantMsg]);
      self.setData({ messages: messages });

      self.streamController = knowledgeChatStream(
        sessionId, query, settings.selectedKnowledgeBaseId,
        {
          onChunk: function(content) {
            var msgs = self.data.messages;
            var last = msgs[msgs.length - 1];
            if (last.thinking && !last.thinkingDone) {
              last.thinkingDone = true;
            }
            last.content += content;
            last.html = markdownToHtml(last.content);
            self.setData({ messages: msgs });
          },
          onThinking: function(content) {
            var msgs = self.data.messages;
            var last = msgs[msgs.length - 1];
            last.thinking += content;
            last.thinkingDone = false;
            self.setData({ messages: msgs });
          },
          onComplete: function() {
            var msgs = self.data.messages;
            var last = msgs[msgs.length - 1];
            last.html = markdownToHtml(last.content);
            self.setData({ messages: msgs, loading: false });
            self.streamController = null;
          },
          onError: function(error) {
            wx.showModal({ title: "Chat failed", content: error.message, showCancel: false });
            self.setData({ loading: false });
            self.streamController = null;
          }
        },
        {
          agentEnabled: settings.agentEnabled,
          agentId: settings.agentId,
          webSearchEnabled: settings.webSearchEnabled
        }
      );
    } catch (error) {
      wx.showModal({ title: "Chat failed", content: error.message, showCancel: false });
      self.setData({ loading: false });
    }
  }
});
