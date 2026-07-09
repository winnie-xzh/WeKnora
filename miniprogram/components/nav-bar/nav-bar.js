Component({
  properties: {
    title: {
      type: String,
      value: "AI 政务助手"
    }
  },

  data: {
    statusBarHeight: 0,
    navBarHeight: 44
  },

  lifetimes: {
    attached() {
      const sysInfo = wx.getSystemInfoSync();
      this.setData({
        statusBarHeight: sysInfo.statusBarHeight,
        navBarHeight: 44
      });
    }
  },

  methods: {
    onMenuTap() {
      this.triggerEvent("menutap");
    }
  }
});
