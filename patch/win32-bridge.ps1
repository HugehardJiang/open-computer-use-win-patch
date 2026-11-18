$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$csharpSource = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Automation;

public static class Win32PatchBridge {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern bool IsHungAppWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern IntPtr ChildWindowFromPointEx(IntPtr hwndParent, POINT pt, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    private static bool _dpiInitialized = false;

    public sealed class CachedNode {
        public AutomationElement Element;
        public IntPtr OwnerHwnd;
        public string Role;
        public string Name;
        public int PhysScreenX;
        public int PhysScreenY;
        public int PhysRelCx;
        public int PhysRelCy;
    }

    public sealed class TopWinInfo {
        public IntPtr Hwnd;
        public int Pid;
        public string Title;
        public RECT Rect;
        public int ZOrder;
        public long Area;
    }

    public sealed class AppSession {
        public int Pid;
        public IntPtr Hwnd;
        public string ProcName;
        public string WinTitle;
        public int WinLeft;
        public int WinTop;
        public int WinW;
        public int WinH;
        public double Scale;
        public List<TopWinInfo> TopWindows = new List<TopWinInfo>();
        public Dictionary<int, CachedNode> Nodes = new Dictionary<int, CachedNode>();
    }

    public sealed class WindowSummary {
        public int Pid;
        public IntPtr Hwnd;
        public string ProcName;
        public string Title;
        public long Score;
    }

    private static readonly Dictionary<string, AppSession> _sessions = new Dictionary<string, AppSession>(StringComparer.OrdinalIgnoreCase);

    public static void EnsureDpiAware() {
        if (_dpiInitialized) return;
        _dpiInitialized = true;
        try {
            if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                SetProcessDPIAware();
            }
        } catch {
            try { SetProcessDPIAware(); } catch { }
        }
    }

    private static bool IsDwmCloaked(IntPtr hwnd) {
        try {
            int cloaked = 0;
            int hr = DwmGetWindowAttribute(hwnd, 14, out cloaked, 4);
            return hr == 0 && cloaked != 0;
        } catch {
            return false;
        }
    }

    public static List<WindowSummary> EnumAppWindows(int excludePid) {
        EnsureDpiAware();
        var bestByPid = new Dictionary<int, WindowSummary>();
        var procNames = new Dictionary<int, string>();

        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            if (IsHungAppWindow(hWnd)) return true;
            bool iconic = IsIconic(hWnd);
            int exStyle = GetWindowLong(hWnd, -20);
            if ((exStyle & 0x00000080) != 0) return true; // WS_EX_TOOLWINDOW
            if (IsDwmCloaked(hWnd)) return true;

            uint pidU;
            GetWindowThreadProcessId(hWnd, out pidU);
            int pid = (int)pidU;
            if (pid <= 0 || pid == excludePid) return true;

            long area = 0;
            if (!iconic) {
                RECT rect;
                if (!GetWindowRect(hWnd, out rect)) return true;
                long w = Math.Max(0, rect.Right - rect.Left);
                long h = Math.Max(0, rect.Bottom - rect.Top);
                area = w * h;
                if (area <= 100) return true;
            }

            string procName;
            if (!procNames.TryGetValue(pid, out procName)) {
                try {
                    procName = Process.GetProcessById(pid).ProcessName;
                } catch {
                    procName = "";
                }
                procNames[pid] = procName;
            }
            if (string.IsNullOrEmpty(procName) ||
                procName.Equals("Idle", StringComparison.OrdinalIgnoreCase) ||
                procName.Equals("System", StringComparison.OrdinalIgnoreCase) ||
                procName.Equals("dwm", StringComparison.OrdinalIgnoreCase)) {
                return true;
            }

            int len = GetWindowTextLength(hWnd);
            string title = "";
            if (len > 0) {
                var sb = new StringBuilder(len + 1);
                GetWindowText(hWnd, sb, sb.Capacity);
                title = sb.ToString().Trim();
            }

            // Skip shell desktop/tray invisible-named Program Manager helper unless iconic/titled
            if (procName.Equals("explorer", StringComparison.OrdinalIgnoreCase) &&
                (title == "" || title == "Program Manager")) {
                return true;
            }

            long score = (iconic ? 1000L : area) + (!string.IsNullOrEmpty(title) ? 1000000000L : 0L);
            WindowSummary existing;
            if (!bestByPid.TryGetValue(pid, out existing) || score > existing.Score) {
                bestByPid[pid] = new WindowSummary {
                    Pid = pid,
                    Hwnd = hWnd,
                    ProcName = procName,
                    Title = string.IsNullOrEmpty(title) ? "untitled" : title,
                    Score = score
                };
            }
            return true;
        }, IntPtr.Zero);

        var result = new List<WindowSummary>(bestByPid.Values);
        result.Sort((a, b) => string.Compare(a.ProcName, b.ProcName, StringComparison.OrdinalIgnoreCase));
        return result;
    }

    public static List<TopWinInfo> CollectWindowsForProc(int targetPid, string procName) {
        EnsureDpiAware();
        var list = new List<TopWinInfo>();
        if (targetPid <= 0 && string.IsNullOrWhiteSpace(procName)) return list;
        var procNames = new Dictionary<int, string>();
        int zOrder = 0;

        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd) || IsIconic(hWnd) || IsHungAppWindow(hWnd)) return true;
            int exStyle = GetWindowLong(hWnd, -20);
            if ((exStyle & 0x00000020) != 0) return true; // WS_EX_TRANSPARENT
            if (IsDwmCloaked(hWnd)) return true;

            uint pidU;
            GetWindowThreadProcessId(hWnd, out pidU);
            int pid = (int)pidU;
            if (pid <= 0) return true;

            if (pid != targetPid) {
                if (string.IsNullOrWhiteSpace(procName)) return true;
                string pName;
                if (!procNames.TryGetValue(pid, out pName)) {
                    try {
                        pName = Process.GetProcessById(pid).ProcessName;
                    } catch {
                        pName = "";
                    }
                    procNames[pid] = pName;
                }
                if (!string.Equals(pName, procName, StringComparison.OrdinalIgnoreCase)) return true;
            }

            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            int w = rect.Right - rect.Left;
            int h = rect.Bottom - rect.Top;
            if (w < 60 || h < 30) return true;

            int len = GetWindowTextLength(hWnd);
            string title = "";
            if (len > 0) {
                var sb = new StringBuilder(len + 1);
                GetWindowText(hWnd, sb, sb.Capacity);
                title = sb.ToString().Trim();
            }
            if (title == "Default IME" || title == "MSCTFIME UI") return true;

            list.Add(new TopWinInfo {
                Hwnd = hWnd,
                Pid = pid,
                Title = title,
                Rect = rect,
                ZOrder = zOrder++,
                Area = (long)w * (long)h
            });
            return true;
        }, IntPtr.Zero);

        return list;
    }

    public static string FastListApps(int excludePid) {
        var list = EnumAppWindows(excludePid);
        var sb = new StringBuilder();
        foreach (var w in list) {
            if (sb.Length > 0) sb.Append('\n');
            sb.Append(w.ProcName).Append(" -- ").Append(w.ProcName)
              .Append(" [running, pid=").Append(w.Pid)
              .Append(", window=").Append(w.Title).Append(']');
        }
        return sb.ToString();
    }

    public static WindowSummary ResolveAppWindow(string query, string alias) {
        var list = EnumAppWindows(0);
        string[] candidates = string.IsNullOrEmpty(alias) || string.Equals(query, alias, StringComparison.OrdinalIgnoreCase)
            ? new[] { query }
            : new[] { query, alias };

        foreach (var cand in candidates) {
            if (string.IsNullOrWhiteSpace(cand)) continue;
            string clean = Path.GetFileNameWithoutExtension(cand.Trim());
            foreach (var w in list) {
                if (w.ProcName.Equals(clean, StringComparison.OrdinalIgnoreCase) ||
                    w.ProcName.Equals(cand.Trim(), StringComparison.OrdinalIgnoreCase)) {
                    return w;
                }
            }
        }
        foreach (var cand in candidates) {
            if (string.IsNullOrWhiteSpace(cand)) continue;
            string clean = Path.GetFileNameWithoutExtension(cand.Trim());
            foreach (var w in list) {
                if (w.ProcName.IndexOf(clean, StringComparison.OrdinalIgnoreCase) >= 0 ||
                    clean.IndexOf(w.ProcName, StringComparison.OrdinalIgnoreCase) >= 0) {
                    return w;
                }
            }
        }
        foreach (var cand in candidates) {
            if (string.IsNullOrWhiteSpace(cand)) continue;
            foreach (var w in list) {
                if (w.Title.IndexOf(cand.Trim(), StringComparison.OrdinalIgnoreCase) >= 0) {
                    return w;
                }
            }
        }
        return null;
    }

    public static IntPtr FindMainWindowByPid(int targetPid) {
        EnsureDpiAware();
        IntPtr bestVisible = IntPtr.Zero;
        long bestVisibleScore = -1;
        IntPtr bestIconic = IntPtr.Zero;

        EnumWindows((hWnd, lParam) => {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if ((int)pid != targetPid) return true;

            bool visible = IsWindowVisible(hWnd);
            bool iconic = IsIconic(hWnd);
            if (!visible && !iconic) return true;
            if (IsHungAppWindow(hWnd)) return true;

            if (iconic) {
                if (bestIconic == IntPtr.Zero) bestIconic = hWnd;
                return true;
            }

            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            long w = Math.Max(0, rect.Right - rect.Left);
            long h = Math.Max(0, rect.Bottom - rect.Top);
            long area = w * h;
            if (area <= 100) return true;

            int titleLen = GetWindowTextLength(hWnd);
            long score = area + (titleLen > 0 ? 1000000000L : 0L);
            if (score > bestVisibleScore) {
                bestVisibleScore = score;
                bestVisible = hWnd;
            }
            return true;
        }, IntPtr.Zero);

        if (bestVisible != IntPtr.Zero) return bestVisible;
        if (bestIconic != IntPtr.Zero) return bestIconic;
        try {
            return Process.GetProcessById(targetPid).MainWindowHandle;
        } catch {
            return IntPtr.Zero;
        }
    }

    public static bool FocusHwnd(IntPtr hWnd) {
        EnsureDpiAware();
        if (hWnd == IntPtr.Zero) return false;
        if (IsIconic(hWnd)) {
            ShowWindow(hWnd, 9);
            Thread.Sleep(150);
        }
        IntPtr fg = GetForegroundWindow();
        if (fg == hWnd) return true;

        uint fgTid = 0;
        if (fg != IntPtr.Zero) {
            uint dummy;
            fgTid = GetWindowThreadProcessId(fg, out dummy);
        }
        uint curTid = GetCurrentThreadId();
        bool attached = false;
        try {
            if (fgTid != 0 && fgTid != curTid) {
                attached = AttachThreadInput(curTid, fgTid, true);
            }
            BringWindowToTop(hWnd);
            ShowWindow(hWnd, 5);
            SetForegroundWindow(hWnd);
        } finally {
            if (attached) {
                AttachThreadInput(curTid, fgTid, false);
            }
        }
        return GetForegroundWindow() == hWnd;
    }

    private static string MapControlTypeCn(ControlType ct) {
        if (ct == null) return "自定义";
        if (ct == ControlType.Window) return "窗口";
        if (ct == ControlType.Button) return "按钮";
        if (ct == ControlType.Edit) return "编辑";
        if (ct == ControlType.Text) return "文本";
        if (ct == ControlType.Group) return "组";
        if (ct == ControlType.CheckBox) return "复选框";
        if (ct == ControlType.RadioButton) return "单选按钮";
        if (ct == ControlType.ComboBox) return "组合框";
        if (ct == ControlType.List) return "列表";
        if (ct == ControlType.ListItem) return "列表项目";
        if (ct == ControlType.Tree) return "树";
        if (ct == ControlType.TreeItem) return "树项目";
        if (ct == ControlType.MenuItem) return "菜单项目";
        if (ct == ControlType.MenuBar) return "菜单栏";
        if (ct == ControlType.Menu) return "菜单";
        if (ct == ControlType.Tab) return "选项卡";
        if (ct == ControlType.TabItem) return "选项卡项目";
        if (ct == ControlType.Pane) return "窗格";
        if (ct == ControlType.Document) return "文档";
        if (ct == ControlType.Hyperlink) return "超链接";
        if (ct == ControlType.Image) return "图像";
        if (ct == ControlType.ScrollBar) return "滚动条";
        if (ct == ControlType.ToolBar) return "工具栏";
        if (ct == ControlType.Slider) return "滑块";
        if (ct == ControlType.Spinner) return "微调器";
        if (ct == ControlType.Table) return "表";
        if (ct == ControlType.DataGrid) return "数据网格";
        if (ct == ControlType.DataItem) return "数据项目";
        return "自定义";
    }

    private static string TruncateText(string text, int maxLen) {
        if (string.IsNullOrEmpty(text)) return "";
        string clean = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
        if (maxLen > 0 && clean.Length > maxLen) {
            return clean.Substring(0, maxLen) + "...";
        }
        return clean;
    }

    private static string FormatRuntimeId(AutomationElement el) {
        if (el == null) return null;
        try {
            int[] rid = el.GetRuntimeId();
            if (rid == null || rid.Length == 0) return null;
            var rsb = new StringBuilder();
            for (int i = 0; i < rid.Length; i++) {
                if (i > 0) rsb.Append('.');
                rsb.Append(rid[i]);
            }
            return rsb.ToString();
        } catch {
            return null;
        }
    }

    private static void WalkUia(
        AutomationElement el,
        int depth,
        int indentLevel,
        int maxDepth,
        int maxNodes,
        int textLimit,
        AppSession session,
        StringBuilder sb,
        ref int nextIdx,
        IntPtr ownerHwnd,
        Dictionary<string, bool> visited,
        Stopwatch walkSw,
        long maxWalkMs,
        ref int rawVisited,
        int maxRawNodes) {
        if (el == null || depth > maxDepth || nextIdx >= maxNodes) return;
        if (rawVisited >= maxRawNodes) return;
        if (walkSw != null && walkSw.ElapsedMilliseconds > maxWalkMs) return;
        rawVisited++;

        string ridKey = FormatRuntimeId(el);
        if (ridKey != null) {
            if (visited.ContainsKey(ridKey)) return;
            visited[ridKey] = true;
        }

        string name = "";
        string cls = "";
        ControlType ct = null;
        Rect rect = Rect.Empty;

        try {
            object nameObj = el.Cached.Name;
            name = nameObj != null ? nameObj.ToString() : "";
            object clsObj = el.Cached.ClassName;
            cls = clsObj != null ? clsObj.ToString() : "";
            ct = el.Cached.ControlType;
            rect = el.Cached.BoundingRectangle;
        } catch {
            return;
        }

        string roleCn = MapControlTypeCn(ct);
        bool isContainerNoise = depth > 0 &&
            (ct == ControlType.Group || ct == ControlType.Custom || ct == ControlType.Pane) &&
            string.IsNullOrWhiteSpace(name);

        int nextIndent = indentLevel;
        if (!isContainerNoise) {
            int idx = nextIdx++;
            string cleanName = TruncateText(name, textLimit);
            for (int t = 0; t < indentLevel; t++) sb.Append('\t');
            sb.Append(idx).Append(' ').Append(roleCn);
            if (!string.IsNullOrEmpty(cleanName)) {
                sb.Append(' ').Append(cleanName);
            }

            if (!rect.IsEmpty &&
                !double.IsInfinity(rect.Width) && !double.IsInfinity(rect.Height) &&
                rect.Width >= 0 && rect.Height >= 0) {
                int rx = (int)Math.Round(rect.Left - session.WinLeft);
                int ry = (int)Math.Round(rect.Top - session.WinTop);
                int rw = (int)Math.Round(rect.Width);
                int rh = (int)Math.Round(rect.Height);
                int scrCx = (int)Math.Round(rect.Left + rect.Width / 2.0);
                int scrCy = (int)Math.Round(rect.Top + rect.Height / 2.0);

                session.Nodes[idx] = new CachedNode {
                    Element = el,
                    OwnerHwnd = ownerHwnd,
                    Role = roleCn,
                    Name = string.IsNullOrEmpty(cleanName) ? roleCn : cleanName,
                    PhysScreenX = scrCx,
                    PhysScreenY = scrCy,
                    PhysRelCx = scrCx - session.WinLeft,
                    PhysRelCy = scrCy - session.WinTop
                };

                int sx = (int)Math.Round(rx * session.Scale);
                int sy = (int)Math.Round(ry * session.Scale);
                int sw = (int)Math.Round(rw * session.Scale);
                int sh = (int)Math.Round(rh * session.Scale);
                sb.Append(" Frame: {x: ").Append(sx)
                  .Append(", y: ").Append(sy)
                  .Append(", width: ").Append(sw)
                  .Append(", height: ").Append(sh).Append('}');
            } else {
                int relCx = session.WinW / 2;
                int relCy = session.WinH / 2;
                session.Nodes[idx] = new CachedNode {
                    Element = el,
                    OwnerHwnd = ownerHwnd,
                    Role = roleCn,
                    Name = string.IsNullOrEmpty(cleanName) ? roleCn : cleanName,
                    PhysScreenX = session.WinLeft + relCx,
                    PhysScreenY = session.WinTop + relCy,
                    PhysRelCx = relCx,
                    PhysRelCy = relCy
                };
            }
            sb.Append('\n');
            nextIndent = indentLevel + 1;
        }

        if (depth >= maxDepth || nextIdx >= maxNodes) return;
        if (rawVisited >= maxRawNodes) return;
        if (walkSw != null && walkSw.ElapsedMilliseconds > maxWalkMs) return;
        if ((!string.IsNullOrEmpty(cls) && cls.IndexOf("KxCefWebView", StringComparison.OrdinalIgnoreCase) >= 0) ||
            string.Equals(name, "Chrome Legacy Window", StringComparison.OrdinalIgnoreCase)) {
            return;
        }

        try {
            AutomationElementCollection children = el.FindAll(TreeScope.Children, Condition.TrueCondition);
            if (children == null) return;
            for (int i = 0; i < children.Count && nextIdx < maxNodes && rawVisited < maxRawNodes; i++) {
                if (walkSw != null && walkSw.ElapsedMilliseconds > maxWalkMs) break;
                WalkUia(children[i], depth + 1, nextIndent, maxDepth, maxNodes, textLimit, session, sb, ref nextIdx, ownerHwnd, visited, walkSw, maxWalkMs, ref rawVisited, maxRawNodes);
            }
        } catch {
            // Skip transient child subtree errors.
        }
    }

    private static ImageCodecInfo GetJpegEncoder() {
        foreach (ImageCodecInfo codec in ImageCodecInfo.GetImageEncoders()) {
            if (codec.FormatID == ImageFormat.Jpeg.Guid) return codec;
        }
        return null;
    }

    private static bool HasNonBlackSamples(Bitmap bmp) {
        int w = bmp.Width;
        int h = bmp.Height;
        for (int ix = 1; ix <= 8; ix++) {
            int px = Math.Min(w - 1, (w * ix) / 9);
            for (int iy = 1; iy <= 8; iy++) {
                int py = Math.Min(h - 1, (h * iy) / 9);
                Color c = bmp.GetPixel(px, py);
                if ((c.R + c.G + c.B) > 0) return true;
            }
        }
        return false;
    }

    public static Dictionary<string, object> FastGetAppState(
        string appQuery,
        string alias,
        bool includeAx,
        bool includeScreenshot,
        int maxNodes,
        int maxDepth,
        int textLimit,
        int maxScreenshotWidth,
        int jpegQuality,
        bool restoreIfMinimized) {

        var result = new Dictionary<string, object>();
        WindowSummary win = ResolveAppWindow(appQuery, alias);
        if (win == null) {
            result["ok"] = false;
            result["notFound"] = true;
            return result;
        }

        IntPtr hwnd = win.Hwnd;
        if (IsIconic(hwnd)) {
            if (restoreIfMinimized) {
                ShowWindow(hwnd, 9);
                Thread.Sleep(150);
            } else {
                result["ok"] = false;
                result["fallback"] = true;
                return result;
            }
        }

        List<TopWinInfo> appWins = CollectWindowsForProc(win.Pid, win.ProcName);
        TopWinInfo primaryWin = null;
        for (int wi = 0; wi < appWins.Count; wi++) {
            bool curIsTarget = (appWins[wi].Pid == win.Pid);
            bool bestIsTarget = (primaryWin != null && primaryWin.Pid == win.Pid);
            if (primaryWin == null ||
                (curIsTarget && !bestIsTarget) ||
                (curIsTarget == bestIsTarget && appWins[wi].Area > primaryWin.Area)) {
                primaryWin = appWins[wi];
            }
        }

        RECT winRect;
        string winTitle = win.Title;
        int targetPid = win.Pid;
        var popupsInFront = new List<TopWinInfo>();
        if (primaryWin != null) {
            hwnd = primaryWin.Hwnd;
            winRect = primaryWin.Rect;
            if (!string.IsNullOrEmpty(primaryWin.Title)) winTitle = primaryWin.Title;
            targetPid = primaryWin.Pid;
            for (int wi = 0; wi < appWins.Count; wi++) {
                if (appWins[wi].ZOrder < primaryWin.ZOrder && appWins[wi].Hwnd != primaryWin.Hwnd) {
                    if (appWins[wi].Pid == primaryWin.Pid || !IsHungAppWindow(appWins[wi].Hwnd)) {
                        popupsInFront.Add(appWins[wi]);
                    }
                }
            }
        } else {
            if (!GetWindowRect(hwnd, out winRect)) {
                result["ok"] = false;
                result["fallback"] = true;
                return result;
            }
        }

        int winW = Math.Max(1, winRect.Right - winRect.Left);
        int winH = Math.Max(1, winRect.Bottom - winRect.Top);
        double scale = (maxScreenshotWidth > 0 && winW > maxScreenshotWidth)
            ? ((double)maxScreenshotWidth / winW)
            : 1.0;

        var session = new AppSession {
            Pid = targetPid,
            Hwnd = hwnd,
            ProcName = win.ProcName,
            WinTitle = winTitle,
            WinLeft = winRect.Left,
            WinTop = winRect.Top,
            WinW = winW,
            WinH = winH,
            Scale = scale,
            TopWindows = appWins
        };

        var sb = new StringBuilder();
        sb.Append("App=").Append(win.ProcName).Append(" (pid ").Append(targetPid).Append(")\n");
        sb.Append("Window: \"").Append(winTitle).Append("\", App: ").Append(win.ProcName).Append(".\n");

        if (includeAx) {
            var cacheReq = new CacheRequest();
            cacheReq.Add(AutomationElement.NameProperty);
            cacheReq.Add(AutomationElement.ClassNameProperty);
            cacheReq.Add(AutomationElement.ControlTypeProperty);
            cacheReq.Add(AutomationElement.BoundingRectangleProperty);
            cacheReq.Add(AutomationElement.IsEnabledProperty);
            cacheReq.TreeScope = TreeScope.Element | TreeScope.Children;

            var visited = new Dictionary<string, bool>();
            var walkSw = Stopwatch.StartNew();
            int rawVisited = 0;
            int maxRawNodes = Math.Max(1500, maxNodes * 5);
            long maxWalkMs = 1500L;

            using (cacheReq.Activate()) {
                int nextIdx = 0;
                for (int pi = 0; pi < popupsInFront.Count && nextIdx < maxNodes && rawVisited < maxRawNodes && walkSw.ElapsedMilliseconds <= maxWalkMs; pi++) {
                    TopWinInfo pop = popupsInFront[pi];
                    try {
                        AutomationElement popRoot = AutomationElement.FromHandle(pop.Hwnd);
                        WalkUia(popRoot, 0, 1, maxDepth, maxNodes, textLimit, session, sb, ref nextIdx, pop.Hwnd, visited, walkSw, maxWalkMs, ref rawVisited, maxRawNodes);
                    } catch { }
                }
                if (nextIdx < maxNodes && rawVisited < maxRawNodes && walkSw.ElapsedMilliseconds <= maxWalkMs) {
                    AutomationElement root = AutomationElement.FromHandle(hwnd);
                    WalkUia(root, 0, 1, maxDepth, maxNodes, textLimit, session, sb, ref nextIdx, hwnd, visited, walkSw, maxWalkMs, ref rawVisited, maxRawNodes);
                }
            }
        }

        _sessions[win.ProcName] = session;
        if (!string.IsNullOrWhiteSpace(appQuery)) {
            _sessions[appQuery.Trim()] = session;
        }

        if (!includeScreenshot) {
            sb.Append("\nScreenshot omitted by include_screenshot=false");
        } else if (winW >= 50 && winH >= 50) {
            Bitmap fullBmp = null;
            Bitmap outBmp = null;
            MemoryStream ms = null;
            EncoderParameters eps = null;
            try {
                fullBmp = new Bitmap(winW, winH, PixelFormat.Format24bppRgb);
                IntPtr fg = GetForegroundWindow();
                bool appIsForeground = (fg == hwnd);
                if (!appIsForeground) {
                    for (int wi = 0; wi < appWins.Count; wi++) {
                        if (appWins[wi].Hwnd == fg) { appIsForeground = true; break; }
                    }
                }

                bool captured = false;
                if (appIsForeground) {
                    using (Graphics g = Graphics.FromImage(fullBmp)) {
                        g.CopyFromScreen(winRect.Left, winRect.Top, 0, 0, new System.Drawing.Size(winW, winH));
                        captured = true;
                    }
                } else {
                    using (Graphics g = Graphics.FromImage(fullBmp)) {
                        IntPtr hdc = g.GetHdc();
                        try {
                            captured = !IsHungAppWindow(hwnd) && PrintWindow(hwnd, hdc, 2);
                        } finally {
                            g.ReleaseHdc(hdc);
                        }
                        if (captured && popupsInFront.Count > 0) {
                            for (int pi = popupsInFront.Count - 1; pi >= 0; pi--) {
                                TopWinInfo pop = popupsInFront[pi];
                                if (IsHungAppWindow(pop.Hwnd)) continue;
                                int pw = pop.Rect.Right - pop.Rect.Left;
                                int ph = pop.Rect.Bottom - pop.Rect.Top;
                                if (pw < 10 || ph < 10) continue;
                                using (Bitmap popBmp = new Bitmap(pw, ph, PixelFormat.Format24bppRgb)) {
                                    bool popOk = false;
                                    using (Graphics pg = Graphics.FromImage(popBmp)) {
                                        IntPtr popHdc = pg.GetHdc();
                                        try {
                                            popOk = !IsHungAppWindow(pop.Hwnd) && PrintWindow(pop.Hwnd, popHdc, 2);
                                        } finally {
                                            pg.ReleaseHdc(popHdc);
                                        }
                                    }
                                    if (popOk && HasNonBlackSamples(popBmp)) {
                                        g.DrawImage(popBmp, pop.Rect.Left - winRect.Left, pop.Rect.Top - winRect.Top, pw, ph);
                                    }
                                }
                            }
                        }
                    }
                    if (!captured || !HasNonBlackSamples(fullBmp)) {
                        using (Graphics g = Graphics.FromImage(fullBmp)) {
                            g.CopyFromScreen(winRect.Left, winRect.Top, 0, 0, new System.Drawing.Size(winW, winH));
                            captured = true;
                        }
                    }
                }

                if (captured) {
                    int imgW = Math.Max(1, (int)Math.Round(winW * scale));
                    int imgH = Math.Max(1, (int)Math.Round(winH * scale));
                    Bitmap srcForSave = fullBmp;
                    if (scale < 0.999) {
                        outBmp = new Bitmap(imgW, imgH, PixelFormat.Format24bppRgb);
                        using (Graphics sg = Graphics.FromImage(outBmp)) {
                            sg.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            sg.PixelOffsetMode = PixelOffsetMode.HighQuality;
                            sg.DrawImage(fullBmp, 0, 0, imgW, imgH);
                        }
                        srcForSave = outBmp;
                    }

                    ms = new MemoryStream();
                    ImageCodecInfo jpg = GetJpegEncoder();
                    if (jpg != null) {
                        eps = new EncoderParameters(1);
                        eps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Math.Max(30, Math.Min(100, jpegQuality)));
                        srcForSave.Save(ms, jpg, eps);
                        result["mimeType"] = "image/jpeg";
                    } else {
                        srcForSave.Save(ms, ImageFormat.Png);
                        result["mimeType"] = "image/png";
                    }
                    result["imageData"] = Convert.ToBase64String(ms.ToArray());
                    result["imgW"] = imgW;
                    result["imgH"] = imgH;
                }
            } finally {
                if (eps != null) eps.Dispose();
                if (ms != null) ms.Dispose();
                if (outBmp != null) outBmp.Dispose();
                if (fullBmp != null) fullBmp.Dispose();
            }
        }

        result["ok"] = true;
        result["pid"] = win.Pid;
        result["app"] = win.ProcName;
        result["scale"] = scale;
        result["winW"] = winW;
        result["winH"] = winH;
        result["text"] = sb.ToString().TrimEnd();
        return result;
    }

    private static AppSession GetValidSession(string appQuery) {
        if (string.IsNullOrWhiteSpace(appQuery)) return null;
        AppSession session;
        if (!_sessions.TryGetValue(appQuery.Trim(), out session)) return null;
        if (session.Hwnd == IntPtr.Zero || !IsWindow(session.Hwnd)) return null;
        uint pid;
        GetWindowThreadProcessId(session.Hwnd, out pid);
        if ((int)pid != session.Pid) return null;
        return session;
    }

    private static bool TryInvokeNode(AutomationElement el) {
        if (el == null) return false;
        object pat;
        try {
            if (el.TryGetCurrentPattern(InvokePattern.Pattern, out pat)) {
                ((InvokePattern)pat).Invoke();
                return true;
            }
        } catch { }
        try {
            if (el.TryGetCurrentPattern(TogglePattern.Pattern, out pat)) {
                ((TogglePattern)pat).Toggle();
                return true;
            }
        } catch { }
        try {
            if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pat)) {
                ((SelectionItemPattern)pat).Select();
                return true;
            }
        } catch { }
        try {
            if (el.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out pat)) {
                var ecp = (ExpandCollapsePattern)pat;
                if (ecp.Current.ExpandCollapseState == ExpandCollapseState.Collapsed) ecp.Expand();
                else ecp.Collapse();
                return true;
            }
        } catch { }
        return false;
    }

    private static IntPtr FindDeepestChildAt(IntPtr rootHwnd, int screenX, int screenY) {
        IntPtr target = rootHwnd;
        for (int depth = 0; depth < 16; depth++) {
            POINT pt = new POINT { X = screenX, Y = screenY };
            if (!ScreenToClient(target, ref pt)) break;
            IntPtr child = ChildWindowFromPointEx(target, pt, 0x0003);
            if (child == IntPtr.Zero || child == target) break;
            target = child;
        }
        return target;
    }

    private static bool IsRenderedWebOrGpuSurface(IntPtr hwnd) {
        IntPtr cur = hwnd;
        for (int depth = 0; depth < 4 && cur != IntPtr.Zero; depth++) {
            var sb = new StringBuilder(128);
            if (GetClassName(cur, sb, sb.Capacity) > 0) {
                string cls = sb.ToString();
                if (cls.IndexOf("Chrome", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    cls.IndexOf("Cef", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    cls.IndexOf("WebView", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    cls.IndexOf("Intermediate D3D Window", StringComparison.OrdinalIgnoreCase) >= 0) {
                    return true;
                }
            }
            cur = GetParent(cur);
        }
        return false;
    }

    private static void PostClickAtScreenPoint(IntPtr rootHwnd, int screenX, int screenY, string mouseButton, int clickCount) {
        IntPtr target = FindDeepestChildAt(rootHwnd, screenX, screenY);
        POINT pt = new POINT { X = screenX, Y = screenY };
        ScreenToClient(target, ref pt);
        IntPtr lParam = (IntPtr)(((pt.Y & 0xFFFF) << 16) | (pt.X & 0xFFFF));

        uint downMsg = 0x0201;
        uint upMsg = 0x0202;
        int downW = 1;
        if (string.Equals(mouseButton, "right", StringComparison.OrdinalIgnoreCase)) {
            downMsg = 0x0204; upMsg = 0x0205; downW = 2;
        } else if (string.Equals(mouseButton, "middle", StringComparison.OrdinalIgnoreCase)) {
            downMsg = 0x0207; upMsg = 0x0208; downW = 16;
        }

        PostMessageW(target, 0x0200, IntPtr.Zero, lParam);
        for (int i = 0; i < Math.Max(1, clickCount); i++) {
            PostMessageW(target, downMsg, (IntPtr)downW, lParam);
            Thread.Sleep(15);
            PostMessageW(target, upMsg, IntPtr.Zero, lParam);
            if (i + 1 < clickCount) Thread.Sleep(40);
        }
    }

    private static void GlobalClickAtScreenPoint(IntPtr hwnd, int screenX, int screenY, string mouseButton, int clickCount) {
        FocusHwnd(hwnd);
        Thread.Sleep(60);
        SetCursorPos(screenX, screenY);
        Thread.Sleep(20);

        uint downFlag = 0x0002;
        uint upFlag = 0x0004;
        if (string.Equals(mouseButton, "right", StringComparison.OrdinalIgnoreCase)) {
            downFlag = 0x0008; upFlag = 0x0010;
        } else if (string.Equals(mouseButton, "middle", StringComparison.OrdinalIgnoreCase)) {
            downFlag = 0x0020; upFlag = 0x0040;
        }

        for (int i = 0; i < Math.Max(1, clickCount); i++) {
            mouse_event(downFlag, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(15);
            mouse_event(upFlag, 0, 0, 0, UIntPtr.Zero);
            if (i + 1 < clickCount) Thread.Sleep(40);
        }
    }

    public static Dictionary<string, object> FastClick(
        string appQuery,
        string elementIndexStr,
        double? x,
        double? y,
        string mouseButton,
        int clickCount,
        string clickMethod) {

        var res = new Dictionary<string, object>();
        AppSession session = GetValidSession(appQuery);
        if (session == null) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }

        string method = string.IsNullOrWhiteSpace(clickMethod) ? "auto" : clickMethod.Trim().ToLowerInvariant();
        if (method == "sky_click") {
            res["ok"] = false;
            res["error"] = "click_method 'sky_click' is not supported on Windows";
            return res;
        }

        CachedNode node = null;
        int physRelX;
        int physRelY;
        int screenX;
        int screenY;
        IntPtr targetRootHwnd = session.Hwnd;
        string label = "";

        if (!string.IsNullOrWhiteSpace(elementIndexStr)) {
            int idx;
            if (!int.TryParse(elementIndexStr.Trim(), out idx) || !session.Nodes.TryGetValue(idx, out node)) {
                res["ok"] = false;
                res["fallback"] = true;
                return res;
            }
            physRelX = node.PhysRelCx;
            physRelY = node.PhysRelCy;
            screenX = node.PhysScreenX;
            screenY = node.PhysScreenY;
            if (node.OwnerHwnd != IntPtr.Zero && IsWindow(node.OwnerHwnd)) {
                targetRootHwnd = node.OwnerHwnd;
            }
            label = node.Name;
        } else if (x.HasValue && y.HasValue) {
            physRelX = (int)Math.Round(x.Value / session.Scale);
            physRelY = (int)Math.Round(y.Value / session.Scale);
            RECT curRect;
            if (!GetWindowRect(session.Hwnd, out curRect)) {
                res["ok"] = false;
                res["fallback"] = true;
                return res;
            }
            screenX = curRect.Left + physRelX;
            screenY = curRect.Top + physRelY;
            if (session.TopWindows != null) {
                for (int wi = 0; wi < session.TopWindows.Count; wi++) {
                    TopWinInfo tw = session.TopWindows[wi];
                    if (!IsWindow(tw.Hwnd)) continue;
                    if (screenX >= tw.Rect.Left && screenX < tw.Rect.Right &&
                        screenY >= tw.Rect.Top && screenY < tw.Rect.Bottom) {
                        targetRootHwnd = tw.Hwnd;
                        break;
                    }
                }
            }
            label = "(" + Math.Round(x.Value).ToString(CultureInfo.InvariantCulture) + ", " + Math.Round(y.Value).ToString(CultureInfo.InvariantCulture) + ")";
        } else {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }

        string btn = string.IsNullOrWhiteSpace(mouseButton) ? "left" : mouseButton.Trim().ToLowerInvariant();
        int count = Math.Max(1, clickCount);

        if (method == "accessibility") {
            if (node == null || !TryInvokeNode(node.Element)) {
                res["ok"] = false;
                res["fallback"] = true;
                return res;
            }
        } else if (method == "global") {
            GlobalClickAtScreenPoint(targetRootHwnd, screenX, screenY, btn, count);
        } else if (method == "app_post") {
            PostClickAtScreenPoint(targetRootHwnd, screenX, screenY, btn, count);
        } else {
            bool invoked = false;
            if (node != null && btn == "left" && count == 1) {
                invoked = TryInvokeNode(node.Element);
            }
            if (!invoked) {
                IntPtr hitChild = FindDeepestChildAt(targetRootHwnd, screenX, screenY);
                if (IsRenderedWebOrGpuSurface(hitChild)) {
                    GlobalClickAtScreenPoint(targetRootHwnd, screenX, screenY, btn, count);
                } else {
                    PostClickAtScreenPoint(targetRootHwnd, screenX, screenY, btn, count);
                }
            }
        }

        res["ok"] = true;
        res["pid"] = session.Pid;
        res["physRelX"] = physRelX;
        res["physRelY"] = physRelY;
        res["label"] = label;
        res["text"] = "Clicked " + (string.IsNullOrEmpty(label) ? "target" : label) + " in " + session.ProcName + " (fast bridge).";
        return res;
    }

    public static Dictionary<string, object> FastSetValue(string appQuery, string elementIndexStr, string value) {
        var res = new Dictionary<string, object>();
        AppSession session = GetValidSession(appQuery);
        int idx;
        CachedNode node;
        if (session == null || !int.TryParse(elementIndexStr, out idx) || !session.Nodes.TryGetValue(idx, out node)) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }
        try {
            object pat;
            if (node.Element.TryGetCurrentPattern(ValuePattern.Pattern, out pat)) {
                ((ValuePattern)pat).SetValue(value ?? "");
                res["ok"] = true;
                res["pid"] = session.Pid;
                res["physRelX"] = node.PhysRelCx;
                res["physRelY"] = node.PhysRelCy;
                res["text"] = "Set value on element " + elementIndexStr + " in " + session.ProcName + " (fast bridge).";
                return res;
            }
        } catch { }
        res["ok"] = false;
        res["fallback"] = true;
        return res;
    }

    private static IntPtr GetFocusedWindowForSession(AppSession session) {
        uint dummy;
        uint tid = GetWindowThreadProcessId(session.Hwnd, out dummy);
        if (tid != 0) {
            GUITHREADINFO gti = new GUITHREADINFO();
            gti.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            if (GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus != IntPtr.Zero) {
                return gti.hwndFocus;
            }
        }
        return session.Hwnd;
    }

    public static Dictionary<string, object> FastTypeText(string appQuery, string text, string keyMethod) {
        var res = new Dictionary<string, object>();
        if (string.Equals(keyMethod, "sky_key", StringComparison.OrdinalIgnoreCase)) {
            res["ok"] = false;
            res["error"] = "key_method 'sky_key' is not supported on Windows";
            return res;
        }
        AppSession session = GetValidSession(appQuery);
        if (session == null) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }
        IntPtr target = GetFocusedWindowForSession(session);
        foreach (char ch in (text ?? "")) {
            PostMessageW(target, 0x0102, (IntPtr)(int)ch, (IntPtr)1);
        }
        res["ok"] = true;
        res["pid"] = session.Pid;
        res["text"] = "Typed " + (text ?? "").Length + " characters in " + session.ProcName + " (fast bridge).";
        return res;
    }

    private static byte MapSingleKeyVk(string key) {
        if (string.IsNullOrWhiteSpace(key)) return 0;
        string k = key.Trim();
        switch (k.ToLowerInvariant()) {
            case "return":
            case "enter": return 0x0D;
            case "tab": return 0x09;
            case "escape":
            case "esc": return 0x1B;
            case "backspace": return 0x08;
            case "delete":
            case "del": return 0x2E;
            case "space": return 0x20;
            case "up": return 0x26;
            case "down": return 0x28;
            case "left": return 0x25;
            case "right": return 0x27;
            case "home": return 0x24;
            case "end": return 0x23;
            case "page_up":
            case "prior": return 0x21;
            case "page_down":
            case "next": return 0x22;
        }
        if (k.Length == 1) {
            char c = char.ToUpperInvariant(k[0]);
            if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return (byte)c;
        }
        if (k.StartsWith("f", StringComparison.OrdinalIgnoreCase) && k.Length <= 3) {
            int fn;
            if (int.TryParse(k.Substring(1), out fn) && fn >= 1 && fn <= 12) {
                return (byte)(0x70 + fn - 1);
            }
        }
        return 0;
    }

    public static Dictionary<string, object> FastPressKey(string appQuery, string key, string keyMethod) {
        var res = new Dictionary<string, object>();
        if (string.Equals(keyMethod, "sky_key", StringComparison.OrdinalIgnoreCase)) {
            res["ok"] = false;
            res["error"] = "key_method 'sky_key' is not supported on Windows";
            return res;
        }
        AppSession session = GetValidSession(appQuery);
        if (session == null || string.IsNullOrWhiteSpace(key) || key.Contains("+")) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }
        byte vk = MapSingleKeyVk(key);
        if (vk == 0) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }

        if (string.Equals(keyMethod, "global", StringComparison.OrdinalIgnoreCase)) {
            FocusHwnd(session.Hwnd);
            Thread.Sleep(50);
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            Thread.Sleep(15);
            keybd_event(vk, 0, 2, UIntPtr.Zero);
        } else {
            IntPtr target = GetFocusedWindowForSession(session);
            PostMessageW(target, 0x0100, (IntPtr)vk, (IntPtr)1);
            Thread.Sleep(15);
            PostMessageW(target, 0x0101, (IntPtr)vk, unchecked((IntPtr)0xC0000001));
        }

        res["ok"] = true;
        res["pid"] = session.Pid;
        res["text"] = "Pressed key '" + key + "' in " + session.ProcName + " (fast bridge).";
        return res;
    }

    public static Dictionary<string, object> FastScroll(string appQuery, string elementIndexStr, string direction, double pages) {
        var res = new Dictionary<string, object>();
        AppSession session = GetValidSession(appQuery);
        if (session == null) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }

        int physRelX = session.WinW / 2;
        int physRelY = session.WinH / 2;
        int idx;
        CachedNode node;
        if (!string.IsNullOrWhiteSpace(elementIndexStr) && int.TryParse(elementIndexStr.Trim(), out idx) && session.Nodes.TryGetValue(idx, out node)) {
            physRelX = node.PhysRelCx;
            physRelY = node.PhysRelCy;
        }

        RECT curRect;
        if (!GetWindowRect(session.Hwnd, out curRect)) {
            res["ok"] = false;
            res["fallback"] = true;
            return res;
        }
        int screenX = curRect.Left + physRelX;
        int screenY = curRect.Top + physRelY;
        IntPtr target = FindDeepestChildAt(session.Hwnd, screenX, screenY);

        string dir = (direction ?? "down").Trim().ToLowerInvariant();
        double mult = pages > 0 ? pages : 1.0;
        int delta = (int)Math.Round(120.0 * mult * 3.0);
        uint msg = 0x020A; // WM_MOUSEWHEEL
        if (dir == "down") delta = -delta;
        else if (dir == "left") { msg = 0x020E; delta = -delta; }
        else if (dir == "right") { msg = 0x020E; }

        IntPtr wParam = (IntPtr)((delta & 0xFFFF) << 16);
        IntPtr lParam = (IntPtr)(((screenY & 0xFFFF) << 16) | (screenX & 0xFFFF));
        PostMessageW(target, msg, wParam, lParam);

        res["ok"] = true;
        res["pid"] = session.Pid;
        res["physRelX"] = physRelX;
        res["physRelY"] = physRelY;
        res["text"] = "Scrolled " + dir + " in " + session.ProcName + " (fast bridge).";
        return res;
    }
}
"@

Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase
[Win32PatchBridge]::EnsureDpiAware()

function Write-JsonResponse($obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Resolve-Alias([string]$name, $aliases) {
    if ([string]::IsNullOrWhiteSpace($name) -or $null -eq $aliases) { return $name }
    $trimmed = $name.Trim()
    foreach ($prop in $aliases.PSObject.Properties) {
        if ($prop.Name -ieq $trimmed) {
            return [string]$prop.Value
        }
    }
    return $trimmed
}

function Invoke-LaunchApp($req) {
    $rawApp = [string]$req.app
    $target = Resolve-Alias $rawApp $req.aliases
    $argsList = @()
    if ($null -ne $req.args) {
        foreach ($a in $req.args) { $argsList += [string]$a }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($target)) { $candidates.Add($target) }
    if (-not [string]::IsNullOrWhiteSpace($rawApp) -and ($rawApp -ine $target)) { $candidates.Add($rawApp) }

    foreach ($cand in $candidates) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            if ($argsList.Count -gt 0 -and ($cand -notmatch '\.lnk$')) {
                Start-Process -FilePath $cand -ArgumentList $argsList
            } else {
                Start-Process -FilePath $cand
            }
            return @{ id = $req.id; ok = $true; launched = $cand; method = "direct_path" }
        }
    }

    $shortcutDirs = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $bestShortcut = $null
    $bestScore = -1
    foreach ($dir in $shortcutDirs) {
        $links = Get-ChildItem -Path $dir -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue
        foreach ($lnk in $links) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($lnk.Name)
            if ($base -match '卸载|uninstall|修复|repair|help|帮助') { continue }
            foreach ($cand in $candidates) {
                $score = -1
                if ($base -ieq $cand) { $score = 100 }
                elseif ($base.StartsWith($cand, [System.StringComparison]::OrdinalIgnoreCase)) { $score = 80 }
                elseif ($base.IndexOf($cand, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $score = 60 }
                if ($score -gt 0) {
                    if ($dir -like "*Start Menu*") { $score += 5 }
                    $score -= [Math]::Min(20, [int]($base.Length / 4))
                    if ($score -gt $bestScore) {
                        $bestScore = $score
                        $bestShortcut = $lnk
                    }
                }
            }
        }
    }

    if ($null -ne $bestShortcut) {
        if ($argsList.Count -gt 0) {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($bestShortcut.FullName)
            if ($sc.TargetPath -and (Test-Path -LiteralPath $sc.TargetPath)) {
                Start-Process -FilePath $sc.TargetPath -ArgumentList $argsList
            } else {
                Start-Process -FilePath $bestShortcut.FullName
            }
        } else {
            Start-Process -FilePath $bestShortcut.FullName
        }
        return @{ id = $req.id; ok = $true; launched = $bestShortcut.FullName; method = "shortcut" }
    }

    $regRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths"
    )
    foreach ($cand in $candidates) {
        $exeNames = @($cand)
        if ($cand -notmatch '\.exe$') { $exeNames += "$cand.exe" }
        foreach ($root in $regRoots) {
            if (-not (Test-Path $root)) { continue }
            $subkeys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($sk in $subkeys) {
                $leaf = Split-Path $sk.Name -Leaf
                if ($exeNames | Where-Object { $leaf -ieq $_ }) {
                    $exePath = (Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue).'(default)'
                    if ($exePath) {
                        $exePath = $exePath.Trim('"')
                        if (Test-Path -LiteralPath $exePath) {
                            if ($argsList.Count -gt 0) {
                                Start-Process -FilePath $exePath -ArgumentList $argsList
                            } else {
                                Start-Process -FilePath $exePath
                            }
                            return @{ id = $req.id; ok = $true; launched = $exePath; method = "app_paths" }
                        }
                    }
                }
            }
        }
    }

    foreach ($cand in $candidates) {
        $cmd = Get-Command -Name $cand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) {
            if ($argsList.Count -gt 0) {
                Start-Process -FilePath $cmd.Source -ArgumentList $argsList
            } else {
                Start-Process -FilePath $cmd.Source
            }
            return @{ id = $req.id; ok = $true; launched = $cmd.Source; method = "path_command" }
        }
    }

    return @{ id = $req.id; ok = $false; error = "Could not locate Windows app '$rawApp' via path, shortcuts, App Paths, or PATH." }
}

function Resolve-TargetPid($req) {
    if ($null -ne $req.pid -and [int]$req.pid -gt 0) {
        return [int]$req.pid
    }
    $appName = [string]$req.app
    if ([string]::IsNullOrWhiteSpace($appName)) { return 0 }
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessName -ieq $appName) -or
        ($_.MainWindowTitle -and $_.MainWindowTitle.IndexOf($appName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    foreach ($p in $procs) {
        $h = [Win32PatchBridge]::FindMainWindowByPid($p.Id)
        if ($h -ne [IntPtr]::Zero) { return $p.Id }
    }
    return 0
}

function Invoke-FocusWindow($req) {
    $targetPid = Resolve-TargetPid $req
    if ($targetPid -le 0) {
        return @{ id = $req.id; ok = $false; error = "Target process not found for focus_window." }
    }
    $hwnd = [Win32PatchBridge]::FindMainWindowByPid($targetPid)
    if ($hwnd -eq [IntPtr]::Zero) {
        return @{ id = $req.id; ok = $false; error = "No window handle found for pid $targetPid." }
    }
    $fg = [Win32PatchBridge]::FocusHwnd($hwnd)
    return @{ id = $req.id; ok = $true; pid = $targetPid; hwnd = $hwnd.ToInt64(); isForeground = $fg }
}

function Invoke-CaptureWindow($req) {
    $targetPid = [int]$req.pid
    if ($targetPid -le 0) {
        return @{ id = $req.id; ok = $false; reason = "invalid_pid" }
    }
    $hwnd = [Win32PatchBridge]::FindMainWindowByPid($targetPid)
    if ($hwnd -eq [IntPtr]::Zero) {
        return @{ id = $req.id; ok = $false; reason = "no_hwnd" }
    }

    $wasIconic = [Win32PatchBridge]::IsIconic($hwnd)
    $restored = $false
    if ($wasIconic) {
        if ($req.restoreIfMinimized -eq $true) {
            [void][Win32PatchBridge]::ShowWindow($hwnd, 9)
            Start-Sleep -Milliseconds 220
            $restored = $true
        } else {
            return @{ id = $req.id; ok = $false; reason = "window_minimized" }
        }
    }

    $fg = [Win32PatchBridge]::GetForegroundWindow()
    if (($fg -eq $hwnd) -and (-not $restored)) {
        return @{ id = $req.id; ok = $true; alreadyForeground = $true; restored = $false }
    }

    $rect = New-Object Win32PatchBridge+RECT
    if (-not [Win32PatchBridge]::GetWindowRect($hwnd, [ref]$rect)) {
        return @{ id = $req.id; ok = $false; reason = "get_window_rect_failed" }
    }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -lt 50 -or $h -lt 50) {
        return @{ id = $req.id; ok = $false; reason = "window_too_small" }
    }

    $bmp = $null
    $g = $null
    $ms = $null
    $hdc = [IntPtr]::Zero
    try {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $printed = [Win32PatchBridge]::PrintWindow($hwnd, $hdc, 2)
        $g.ReleaseHdc($hdc)
        $hdc = [IntPtr]::Zero
        if (-not $printed) {
            return @{ id = $req.id; ok = $false; reason = "printwindow_failed"; restored = $restored }
        }

        $hasNonBlack = $false
        for ($ix = 1; $ix -le 8 -and (-not $hasNonBlack); $ix++) {
            $px = [Math]::Min($w - 1, [int](($w * $ix) / 9))
            for ($iy = 1; $iy -le 8; $iy++) {
                $py = [Math]::Min($h - 1, [int](($h * $iy) / 9))
                $c = $bmp.GetPixel($px, $py)
                if (($c.R + $c.G + $c.B) -gt 0) {
                    $hasNonBlack = $true
                    break
                }
            }
        }
        if (-not $hasNonBlack) {
            return @{ id = $req.id; ok = $false; reason = "blank_printwindow"; restored = $restored }
        }

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        return @{
            id = $req.id
            ok = $true
            alreadyForeground = $false
            restored = $restored
            width = $w
            height = $h
            data = $b64
        }
    } finally {
        if ($hdc -ne [IntPtr]::Zero -and $null -ne $g) { try { $g.ReleaseHdc($hdc) } catch {} }
        if ($null -ne $g) { $g.Dispose() }
        if ($null -ne $bmp) { $bmp.Dispose() }
        if ($null -ne $ms) { $ms.Dispose() }
    }
}

Write-JsonResponse @{ ready = $true }

while ($null -ne ($line = [Console]::In.ReadLine())) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed)) { continue }
    $req = $null
    try {
        $req = $trimmed | ConvertFrom-Json
        switch ([string]$req.action) {
            "launch_app" { Write-JsonResponse (Invoke-LaunchApp $req) }
            "focus_window" { Write-JsonResponse (Invoke-FocusWindow $req) }
            "capture_window" { Write-JsonResponse (Invoke-CaptureWindow $req) }
            "fast_list_apps" {
                $exPid = if ($null -ne $req.excludePid) { [int]$req.excludePid } else { 0 }
                $txt = [Win32PatchBridge]::FastListApps($exPid)
                Write-JsonResponse @{ id = $req.id; ok = $true; text = $txt }
            }
            "fast_get_app_state" {
                $rawApp = [string]$req.app
                $alias = Resolve-Alias $rawApp $req.aliases
                $incAx = if ($null -ne $req.includeAx) { [bool]$req.includeAx } else { $true }
                $incShot = if ($null -ne $req.includeScreenshot) { [bool]$req.includeScreenshot } else { $true }
                $mNodes = if ($null -ne $req.maxNodes) { [int]$req.maxNodes } else { 600 }
                $mDepth = if ($null -ne $req.maxDepth) { [int]$req.maxDepth } else { 48 }
                $tLimit = if ($null -ne $req.textLimit) { [int]$req.textLimit } else { 500 }
                $mWidth = if ($null -ne $req.maxScreenshotWidth) { [int]$req.maxScreenshotWidth } else { 1280 }
                $jq = if ($null -ne $req.jpegQuality) { [int]$req.jpegQuality } else { 82 }
                $rest = if ($null -ne $req.restoreIfMinimized) { [bool]$req.restoreIfMinimized } else { $true }
                $r = [Win32PatchBridge]::FastGetAppState($rawApp, $alias, $incAx, $incShot, $mNodes, $mDepth, $tLimit, $mWidth, $jq, $rest)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            "fast_click" {
                $nx = if ($null -ne $req.x) { [Nullable[double]][double]$req.x } else { $null }
                $ny = if ($null -ne $req.y) { [Nullable[double]][double]$req.y } else { $null }
                $cc = if ($null -ne $req.clickCount) { [int]$req.clickCount } else { 1 }
                $r = [Win32PatchBridge]::FastClick([string]$req.app, [string]$req.elementIndex, $nx, $ny, [string]$req.mouseButton, $cc, [string]$req.clickMethod)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            "fast_set_value" {
                $r = [Win32PatchBridge]::FastSetValue([string]$req.app, [string]$req.elementIndex, [string]$req.value)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            "fast_type_text" {
                $r = [Win32PatchBridge]::FastTypeText([string]$req.app, [string]$req.text, [string]$req.keyMethod)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            "fast_press_key" {
                $r = [Win32PatchBridge]::FastPressKey([string]$req.app, [string]$req.key, [string]$req.keyMethod)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            "fast_scroll" {
                $pg = if ($null -ne $req.pages) { [double]$req.pages } else { 1.0 }
                $r = [Win32PatchBridge]::FastScroll([string]$req.app, [string]$req.elementIndex, [string]$req.direction, $pg)
                $r["id"] = $req.id
                Write-JsonResponse $r
            }
            default { Write-JsonResponse @{ id = $req.id; ok = $false; error = "Unknown action: $($req.action)" } }
        }
    } catch {
        $rid = if ($null -ne $req) { $req.id } else { $null }
        Write-JsonResponse @{ id = $rid; ok = $false; fallback = $true; error = $_.Exception.Message }
    }
}
