import SwiftUI

struct HelpView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Label("Capture 使用指南",systemImage:"sparkles").font(.system(size:20,weight:.semibold)).foregroundStyle(CaptureTheme.accent)
                section("一张截图，两个节奏", "快捷键 \(store.preferences.shortcut.display) 呼出区域截图。默认先定格画面，框选后可拖动边缘或整个选区、选择本次样式；回车确认，Esc 取消。设置中的「快速截图」为松手即复制。空格切换窗口选择。")
                section("录屏与声音", "从菜单栏「录制屏幕」呼出，独立快捷键可在设置中修改。快捷键直接框选，默认松手后倒计时录制；在小浮条切到「框选调整」可拖动框内移动、拖动边角缩放，再回车开始。声音、画质和更多配置也能就地修改，倒计时可点调整返回当前范围；电脑声音和麦克风分别开关，麦克风默认关闭。录制中可暂停、继续，按录屏快捷键停止。结束后可播放、另存或复制视频文件；关闭窗口不删除本地作品，可从录屏页下方找回。双音源混音会预留音量余量，建议回放确认。")
                section("登录时启动", "在菜单栏的设置中开启「登录时启动」，下次登录 Mac 时 Capture 自动出现在菜单栏。若显示等待批准，点「打开系统登录项」允许 Capture；返回后自动刷新。关闭开关即可停止自启动，不会退出当前应用。")
                section("默认预设与当前图片", "菜单栏开启自动样式后，新截图使用已命名的默认预设。编辑当前图片不覆盖默认预设；在预设管理中点「设为截图默认」才会改变后续截图。支持搜索、导入和导出预设。")
                section("清晰度与像素", "编辑器默认适应窗口，可能缩小显示。切换 100% 会按一个图片像素对应一个屏幕像素展示，超出视口可滚动。1× PNG 保留原始像素；2×、3× 只会放大，不会增加细节。原图对比不影响正常复制和导出。")
                section("编辑与键盘", "⌘C 复制当前成品，⌘S 导出图片，⇧⌘S 保存项目，⌘Z 撤销，⇧⌘Z 重做，⌘W 关闭窗口。文字输入框保留原生复制粘贴和撤销。标注选择工具选中后可拖动，Delete 删除；一笔手绘为一步撤销。")
                section("项目和隐私", "可编辑 .capture 项目包含未经遮挡的原图，适合自己留存。对外分享使用 PNG / JPEG。历史默认关闭，仅保留本次运行的最近图片；开启本地历史后保留 7 或 30 天，并受 32 张、256 MB 上限约束。收藏也受上限约束。关闭不会删除已有历史。")
                section("置顶与穿透", "置顶图片用于参考，支持透明度和鼠标穿透。开启穿透后，从菜单栏「置顶图片 → 恢复全部交互」恢复，或选择关闭全部。")
                section("权限与恢复", "屏幕录制权限用于你触发的截图、长截图或明确开始的录屏。麦克风只在开启并开始录屏后收音。已允许却无法截图时，先退出后重新打开当前版本；在设置中刷新权限。固定签名确保更新保持身份一致。不要同时运行多个旧版本。")
                section("分享与存储", "系统分享会先准备当前成品，由你选择目标应用；不会自动发送。关闭窗口后 Capture 仍驻留菜单栏。关闭历史时未保存的截图在退出后丢失，请及时导出图片或保存项目。")
            }.padding(30)
        }.background(CaptureTheme.chrome)
    }
    private func section(_ title:String,_ text:String) -> some View {
        VStack(alignment:.leading,spacing:8) { Text(title).font(.headline); Text(text).font(.system(size:13)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
