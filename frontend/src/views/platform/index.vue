<template>
    <div class="main" :class="{ 'is-mobile-layout': isMobile }" ref="dropzone">
        <!-- 移动端顶部栏 -->
        <div v-if="isMobile" class="mobile-header">
            <div class="mobile-header-inner">
                <div class="mobile-header-left" @click="toggleMobileSidebar">
                    <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <line x1="3" y1="6" x2="21" y2="6"/>
                        <line x1="3" y1="12" x2="21" y2="12"/>
                        <line x1="3" y1="18" x2="21" y2="18"/>
                    </svg>
                </div>
                <div class="mobile-header-center">
                    <img class="mobile-logo" src="@/assets/img/weknora.png" alt="WeKnora">
                </div>
                <div class="mobile-header-right">
                    <UserMenu />
                </div>
            </div>
        </div>
        <!-- 桌面端侧边栏 -->
        <Menu v-if="!isMobile" />
        <!-- 移动端侧边栏抽屉 -->
        <template v-if="isMobile">
            <transition name="mobile-sidebar-fade">
                <div v-if="showMobileSidebar" class="mobile-sidebar-backdrop" @click="closeMobileSidebar" />
            </transition>
            <transition name="mobile-sidebar-slide">
                <div v-if="showMobileSidebar" class="mobile-sidebar-drawer">
                    <Menu />
                </div>
            </transition>
        </template>
        <div v-if="isRouterAlive" class="platform-route-outlet">
            <RouterView />
        </div>
        <div class="upload-mask" v-show="ismask">
            <input type="file" style="display: none" ref="uploadInput" accept=".pdf,.docx,.doc,.pptx,.ppt,.epub,.mhtml,.txt,.md,.jpg,.jpeg,.png,.csv,.xls,.xlsx" />
            <UploadMask></UploadMask>
        </div>
        <!-- 全局设置模态框，供所有 platform 子路由使用 -->
        <Settings />
        <!-- 全局命令面板 (⌘K)，随 platform 路由存活 -->
        <GlobalCommandPalette />
        <!-- 全局右上角"待处理邀请"铃铛。固定定位，z-index 低于抽屉，业务页面
             右侧抽屉弹出时会自然覆盖；仅在有待处理邀请时渲染。 -->
        <GlobalInvitationBell />
        <!-- 带遮罩层的新手引导：首次进入自动开启，可从用户菜单顶部昵称旁帮助按钮重新打开 -->
        <NewUserGuide />
    </div>
</template>
<script setup lang="ts">
import Menu from '@/components/menu.vue'
import UserMenu from '@/components/UserMenu.vue'
import { ref, onMounted, onUnmounted, nextTick, provide, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useUIStore } from '@/stores/ui'
import useKnowledgeBase from '@/hooks/useKnowledgeBase'
import UploadMask from '@/components/upload-mask.vue'
import Settings from '@/views/settings/Settings.vue'
import GlobalCommandPalette from '@/components/GlobalCommandPalette.vue'
import GlobalInvitationBell from '@/components/GlobalInvitationBell.vue'
import NewUserGuide from '@/components/NewUserGuide.vue'
import { useCommandPaletteStore } from '@/stores/commandPalette'
import { useChatResourcesStore } from '@/stores/chatResources'
import { getKnowledgeBaseById } from '@/api/knowledge-base/index'
import { MessagePlugin } from 'tdesign-vue-next'
import { useI18n } from 'vue-i18n'

let { requestMethod } = useKnowledgeBase()
const route = useRoute();
const router = useRouter();
const uiStore = useUIStore()
const commandPaletteStore = useCommandPaletteStore();
let ismask = ref(false)
let uploadInput = ref();
const { t } = useI18n();

const isMobile = ref(false)
const showMobileSidebar = ref(false)

const toggleMobileSidebar = () => {
    showMobileSidebar.value = !showMobileSidebar.value
    if (showMobileSidebar.value) {
        uiStore.expandSidebar()
    }
}

const closeMobileSidebar = () => {
    showMobileSidebar.value = false
}

const isRouterAlive = ref(true)
const reloadApp = () => {
    isRouterAlive.value = false
    nextTick(() => {
        isRouterAlive.value = true
    })
}
provide('app:reload', reloadApp)

// 仅在 Wails 桌面端运行时拦截 Cmd/Ctrl+R：
// 桌面端没有浏览器地址栏，整页重载会白屏，所以用前端软刷新替代。
// 浏览器（含 Web 版 / 非 Lite 部署）里不拦截，交给浏览器做真正的整页刷新，
// 否则会出现左侧菜单、全局设置、Pinia store 等不随"刷新"一起重置的问题。
// @ts-ignore
const isWailsDesktop = typeof window !== 'undefined' && !!(window as any).runtime?.EventsOn

const handleGlobalKeyDown = (e: KeyboardEvent) => {
    if (!isWailsDesktop) return
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'r') {
        e.preventDefault()
        reloadApp()
    }
}

// 移动端匹配媒体查询：宽度 ≤ 768px 时自动折叠侧栏
const MOBILE_MEDIA_QUERY = '(max-width: 768px)'
let mobileMediaQuery: MediaQueryList | null = null
const handleMobileMediaChange = (e: MediaQueryListEvent | MediaQueryList) => {
  if (e.matches) {
    isMobile.value = true
    showMobileSidebar.value = false
  } else {
    isMobile.value = false
  }
}

// 用于跟踪拖拽进入/离开的计数器，解决子元素触发 dragleave 的问题
let dragCounter = 0;

// 获取当前知识库ID
const getCurrentKbId = (): string | null => {
    return (route.params as any)?.kbId as string || null
}

const CHAT_DROP_ROUTE_NAMES = new Set(['chat', 'globalCreatChat', 'kbCreatChat']);

const isChatDropRoute = () => {
    return CHAT_DROP_ROUTE_NAMES.has(String(route.name || ''));
}

const collectDroppedFiles = async (event: DragEvent): Promise<File[]> => {
    const dataTransferFiles = event.dataTransfer?.files ? Array.from(event.dataTransfer.files) : [];
    if (dataTransferFiles.length > 0) {
        return dataTransferFiles;
    }

    const dataTransferItems = event.dataTransfer?.items ? Array.from(event.dataTransfer.items) : [];
    if (dataTransferItems.length === 0) {
        return [];
    }

    const files = await Promise.all(dataTransferItems.map(item => new Promise<File | null>((resolve) => {
        const fileEntry = (item as any).webkitGetAsEntry?.();
        if (fileEntry?.isFile && typeof fileEntry.file === 'function') {
            fileEntry.file((file: File) => resolve(file), () => resolve(null));
            return;
        }
        resolve(null);
    })));

    return files.filter((file): file is File => file instanceof File);
}

// 检查知识库初始化状态
const checkKnowledgeBaseInitialization = async (): Promise<boolean> => {
    const currentKbId = getCurrentKbId();
    
    if (!currentKbId) {
        MessagePlugin.error(t('knowledgeBase.missingId'));
        return false;
    }
    
    try {
        const kbResponse = await getKnowledgeBaseById(currentKbId);
        const kb = kbResponse.data;
        
        if (!kb.summary_model_id) {
            MessagePlugin.warning(t('knowledgeBase.notInitialized'));
            return false;
        }
        const strategy = kb.indexing_strategy;
        const needsEmbedding = !strategy || strategy.vector_enabled || strategy.keyword_enabled;
        if (needsEmbedding && !kb.embedding_model_id) {
            MessagePlugin.warning(t('knowledgeBase.notInitialized'));
            return false;
        }
        return true;
    } catch (error) {
        MessagePlugin.error(t('knowledgeBase.getInfoFailed'));
        return false;
    }
}


// isFileDrag distinguishes an OS file drag (the only thing the global upload
// drop zone cares about) from an in-app element drag such as the wiki
// folder/page drag-and-drop. Element drags carry only "text/*" types, never
// "Files", so we bail out and let the originating component handle the drop.
const isFileDrag = (event: DragEvent): boolean => {
    const types = event.dataTransfer?.types
    if (!types) return false
    return Array.from(types).includes('Files')
}

// 全局拖拽事件处理
const handleGlobalDragEnter = (event: DragEvent) => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    dragCounter++;
    if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = 'all';
    }
    ismask.value = true;
}

const handleGlobalDragOver = (event: DragEvent) => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    if (event.dataTransfer) {
        event.dataTransfer.dropEffect = 'copy';
    }
}

const handleGlobalDragLeave = (event: DragEvent) => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    dragCounter--;
    if (dragCounter === 0) {
        ismask.value = false;
    }
}

const handleGlobalDrop = async (event: DragEvent) => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    dragCounter = 0;
    ismask.value = false;

    const droppedFiles = await collectDroppedFiles(event);
    if (droppedFiles.length === 0) {
        MessagePlugin.warning(t('knowledgeBase.dragFileNotText'));
        return;
    }

    if (isChatDropRoute()) {
        event.stopPropagation();
        window.dispatchEvent(new CustomEvent('weknora:chat-file-drop', {
            detail: { files: droppedFiles }
        }));
        return;
    }
    
    const isInitialized = await checkKnowledgeBaseInitialization();
    if (!isInitialized) {
        return;
    }

    droppedFiles.forEach(file => requestMethod(file, uploadInput));
}

// 组件挂载时添加全局事件监听器
onMounted(() => {
    // 移动端侧栏折叠
    mobileMediaQuery = window.matchMedia(MOBILE_MEDIA_QUERY)
    handleMobileMediaChange(mobileMediaQuery)
    mobileMediaQuery.addEventListener('change', handleMobileMediaChange)

    document.addEventListener('dragenter', handleGlobalDragEnter, true);
    document.addEventListener('dragover', handleGlobalDragOver, true);
    document.addEventListener('dragleave', handleGlobalDragLeave, true);
    document.addEventListener('drop', handleGlobalDrop, true);
    if (isWailsDesktop) {
        window.addEventListener('keydown', handleGlobalKeyDown);
        // @ts-ignore
        window.runtime.EventsOn('app:reload', () => {
            reloadApp()
        })
    }
    // 支持通过 URL 查询参数打开全局命令面板，例如旧路径
    // /platform/knowledge-search?q=foo 重定向后携带 ?cmdk=foo
    maybeOpenCmdkFromRoute()
    // 后台预取对话输入栏资源，进入 creatChat / chat 时复用缓存
    void useChatResourcesStore().prefetchChatInput()
});

// 监听路由变化，兼容 SPA 内部跳转时的 ?cmdk= 参数
watch(() => route.query.cmdk, () => {
    maybeOpenCmdkFromRoute()
})

function maybeOpenCmdkFromRoute() {
    if (!('cmdk' in route.query)) return
    const q = String(route.query.cmdk ?? '')
    commandPaletteStore.openPalette(q)
    // 清除 query，避免回退/刷新时反复触发
    const newQuery = { ...route.query }
    delete (newQuery as any).cmdk
    router.replace({ path: route.path, query: newQuery, hash: route.hash })
}

// 组件卸载时移除全局事件监听器
onUnmounted(() => {
    if (mobileMediaQuery) {
      mobileMediaQuery.removeEventListener('change', handleMobileMediaChange)
      mobileMediaQuery = null
    }
    document.removeEventListener('dragenter', handleGlobalDragEnter, true);
    document.removeEventListener('dragover', handleGlobalDragOver, true);
    document.removeEventListener('dragleave', handleGlobalDragLeave, true);
    document.removeEventListener('drop', handleGlobalDrop, true);
    if (isWailsDesktop) {
        window.removeEventListener('keydown', handleGlobalKeyDown);
        // @ts-ignore
        if (window.runtime?.EventsOff) {
            // @ts-ignore
            window.runtime.EventsOff('app:reload')
        }
    }
    dragCounter = 0;
});
</script>
<style lang="less">
.main {
    display: flex;
    align-items: stretch;
    width: 100%;
    height: 100%;
    min-width: 0;
    min-height: 0;
    /* 统一整页背景，让左侧菜单与右侧内容区视觉连贯 */
    background: var(--td-bg-color-container);
}

/* 右侧路由区：占满剩余宽度与整列高度，并把 min-height:0 传给子页面以便内部 flex 滚动 */
.platform-route-outlet {
    flex: 1;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.main.is-mobile-layout {
    flex-direction: column;
    min-width: 0;
    height: 100%;
    overflow: hidden;
    position: relative;
}

.main.is-mobile-layout .platform-route-outlet {
    flex: 1;
    min-height: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
}

/* 移动端顶部栏 */
.mobile-header {
    flex-shrink: 0;
    background: var(--td-bg-color-container);
    border-bottom: 1px solid var(--td-component-stroke);
    z-index: 100;
    position: sticky;
    top: 0;
    width: 100%;
}

html.wails-desktop .mobile-header {
    padding-top: 30px;
}

.mobile-header-inner {
    display: flex;
    align-items: center;
    height: 48px;
    padding: 0 12px;
    gap: 12px;
    box-sizing: border-box;
}

.mobile-header-left {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 8px;
    cursor: pointer;
    color: var(--td-text-color-primary);
    flex-shrink: 0;
    transition: background-color 0.15s ease;
}

.mobile-header-left:active {
    background: var(--td-bg-color-container-hover);
}

.mobile-header-left svg {
    display: block;
}

.mobile-header-center {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    min-width: 0;
    overflow: hidden;
}

.mobile-logo {
    height: 22px;
    width: auto;
    object-fit: contain;
}

.mobile-header-right {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
}

/* 移动端顶部栏用户菜单：仅显示头像，下拉菜单从顶部向下弹出 */
.mobile-header-right .user-menu {
    position: static;
}

.mobile-header-right .user-button {
    justify-content: center;
    padding: 2px 2px;
    gap: 0;
}

.mobile-header-right .user-info,
.mobile-header-right .dropdown-icon {
    display: none !important;
}

.mobile-header-right .user-avatar {
    width: 26px;
    height: 26px;
}

.mobile-header-right .user-avatar .avatar-placeholder {
    font-size: 13px;
}

.mobile-header-right .user-dropdown {
    top: calc(100% + 6px);
    bottom: auto;
    left: auto;
    right: -4px;
    min-width: 220px;
}

/* 移动端侧边栏遮罩 */
.mobile-sidebar-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.35);
    z-index: 900;
}

/* 移动端侧边栏抽屉 */
.mobile-sidebar-drawer {
    position: fixed;
    top: 0;
    left: 0;
    height: 100%;
    width: 280px;
    max-width: 85vw;
    z-index: 901;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    background: var(--td-bg-color-sidebar, var(--td-bg-color-container));
    box-shadow: 2px 0 12px rgba(0, 0, 0, 0.12);
}

.mobile-sidebar-drawer .aside_box {
    width: 100%;
    min-width: 0;
    height: 100%;
    border-right: none;
    border-radius: 0;
    flex: 1;
}

.mobile-sidebar-drawer .sidebar-toggle,
.mobile-sidebar-drawer .sidebar-toggle-item {
    display: none !important;
}

.mobile-sidebar-drawer .sidebar-drag-handle {
    display: none !important;
}

.mobile-sidebar-drawer .menu_bottom {
    display: none !important;
}

/* 动画 */
.mobile-sidebar-fade-enter-active,
.mobile-sidebar-fade-leave-active {
    transition: opacity 0.22s ease;
}

.mobile-sidebar-fade-enter-from,
.mobile-sidebar-fade-leave-to {
    opacity: 0;
}

.mobile-sidebar-slide-enter-active,
.mobile-sidebar-slide-leave-active {
    transition: transform 0.25s cubic-bezier(0.25, 0.46, 0.45, 0.94);
}

.mobile-sidebar-slide-enter-from,
.mobile-sidebar-slide-leave-to {
    transform: translateX(-100%);
}

/* 深色模式 logo 反色 */
html[theme-mode="dark"] .mobile-logo {
    filter: invert(1) hue-rotate(180deg);
}

.upload-mask {
    background-color: rgba(255, 255, 255, 0.8);
    position: fixed;
    width: 100%;
    height: 100%;
    z-index: 999;
    display: flex;
    justify-content: center;
    align-items: center;
}

img {
    -webkit-user-drag: none;
    -khtml-user-drag: none;
    -moz-user-drag: none;
    -o-user-drag: none;
    user-drag: none;
}
</style>
