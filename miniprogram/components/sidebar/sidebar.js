Component({
  properties: {
    show: {
      type: Boolean,
      value: false,
      observer(newVal) {
        if (newVal) {
          this.setData({ animating: true, visible: true });
        } else if (this.data.visible) {
          this.setData({ animating: false });
        }
      }
    },
    menus: {
      type: Array,
      value: [
        { key: "knowledge", label: "知识库", icon: "📚" },
        { key: "chat", label: "对话", icon: "💬" }
      ]
    },
    activeKey: {
      type: String,
      value: ""
    },
    profileName: {
      type: String,
      value: "AI 政务助手"
    }
  },

  data: {
    animating: false,
    visible: false
  },

  methods: {
    onOverlayTap() {
      this.triggerEvent("close");
    },

    onItemTap(e) {
      const key = e.currentTarget.dataset.key;
      if (key) {
        this.triggerEvent("itemtap", { key: key });
      }
    },

    onTransitionEnd() {
      if (!this.data.animating) {
        this.setData({ visible: false });
      }
    }
  }
});
