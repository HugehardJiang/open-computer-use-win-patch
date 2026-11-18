param(
    [int]$IdleHideMs = 4500,
    [int]$MaxAlpha = 96
)

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$csharp = @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class OverlayNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE {
        public int Width;
        public int Height;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO {
        public BITMAPINFOHEADER bmiHeader;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

    [DllImport("user32.dll")]
    public static extern bool UpdateLayeredWindow(
        IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateDIBSection(
        IntPtr hdc, ref BITMAPINFO pbmi, uint usage, out IntPtr ppvBits, IntPtr hSection, uint offset);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    public const int WS_POPUP = unchecked((int)0x80000000);
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;
    public const int ULW_ALPHA = 2;

    public static void EnsureDpiAware() {
        try {
            if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                SetProcessDPIAware();
            }
        } catch {
            try { SetProcessDPIAware(); } catch { }
        }
    }

    public static bool FindWindowRectByPid(int targetPid, out RECT outRect) {
        outRect = new RECT();
        if (targetPid <= 0) return false;

        RECT bestRect = new RECT();
        long bestScore = -1;

        EnumWindows((hWnd, lParam) => {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if ((int)pid != targetPid) return true;
            if (!IsWindowVisible(hWnd) || IsIconic(hWnd)) return true;

            RECT r;
            if (!GetWindowRect(hWnd, out r)) return true;
            long w = Math.Max(0, r.Right - r.Left);
            long h = Math.Max(0, r.Bottom - r.Top);
            long area = w * h;
            if (area <= 100) return true;

            int titleLen = GetWindowTextLength(hWnd);
            long score = area + (titleLen > 0 ? 1000000000L : 0L);
            if (score > bestScore) {
                bestScore = score;
                bestRect = r;
            }
            return true;
        }, IntPtr.Zero);

        if (bestScore > 0) {
            outRect = bestRect;
            return true;
        }
        return false;
    }
}

public sealed class LayeredStripWindow : NativeWindow, IDisposable {
    public readonly int WinX;
    public readonly int WinY;
    public readonly int WinW;
    public readonly int WinH;
    public readonly int[] Pixels;

    private IntPtr _memDc;
    private IntPtr _dib;
    private IntPtr _oldBmp;
    private IntPtr _bitsPtr;
    private bool _visible;
    private bool _disposed;

    public LayeredStripWindow(int x, int y, int w, int h) {
        WinX = x;
        WinY = y;
        WinW = Math.Max(1, w);
        WinH = Math.Max(1, h);
        Pixels = new int[WinW * WinH];

        CreateParams cp = new CreateParams();
        cp.Caption = "OcuEdgeOverlay";
        cp.Style = OverlayNative.WS_POPUP;
        cp.ExStyle = OverlayNative.WS_EX_LAYERED | OverlayNative.WS_EX_TRANSPARENT |
                     OverlayNative.WS_EX_TOPMOST | OverlayNative.WS_EX_TOOLWINDOW |
                     OverlayNative.WS_EX_NOACTIVATE;
        cp.X = WinX;
        cp.Y = WinY;
        cp.Width = WinW;
        cp.Height = WinH;
        CreateHandle(cp);

        OverlayNative.SetWindowDisplayAffinity(Handle, OverlayNative.WDA_EXCLUDEFROMCAPTURE);

        IntPtr screenDc = OverlayNative.GetDC(IntPtr.Zero);
        try {
            _memDc = OverlayNative.CreateCompatibleDC(screenDc);
            OverlayNative.BITMAPINFO bmi = new OverlayNative.BITMAPINFO();
            bmi.bmiHeader.biSize = (uint)Marshal.SizeOf(typeof(OverlayNative.BITMAPINFOHEADER));
            bmi.bmiHeader.biWidth = WinW;
            bmi.bmiHeader.biHeight = -WinH;
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = 0;

            _dib = OverlayNative.CreateDIBSection(_memDc, ref bmi, 0, out _bitsPtr, IntPtr.Zero, 0);
            _oldBmp = OverlayNative.SelectObject(_memDc, _dib);
        } finally {
            OverlayNative.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    public void Show() {
        if (!_visible && Handle != IntPtr.Zero) {
            OverlayNative.ShowWindow(Handle, OverlayNative.SW_SHOWNOACTIVATE);
            _visible = true;
        }
    }

    public void Hide() {
        if (_visible && Handle != IntPtr.Zero) {
            OverlayNative.ShowWindow(Handle, OverlayNative.SW_HIDE);
            _visible = false;
        }
    }

    public void Present(byte constAlpha) {
        if (_disposed || Handle == IntPtr.Zero || _bitsPtr == IntPtr.Zero) return;
        Show();
        Marshal.Copy(Pixels, 0, _bitsPtr, Pixels.Length);

        OverlayNative.POINT dst = new OverlayNative.POINT { X = WinX, Y = WinY };
        OverlayNative.SIZE sz = new OverlayNative.SIZE { Width = WinW, Height = WinH };
        OverlayNative.POINT src = new OverlayNative.POINT { X = 0, Y = 0 };
        OverlayNative.BLENDFUNCTION blend = new OverlayNative.BLENDFUNCTION {
            BlendOp = 0,
            BlendFlags = 0,
            SourceConstantAlpha = constAlpha,
            AlphaFormat = 1
        };
        OverlayNative.UpdateLayeredWindow(Handle, IntPtr.Zero, ref dst, ref sz, _memDc, ref src, 0, ref blend, OverlayNative.ULW_ALPHA);
    }

    public void Dispose() {
        if (_disposed) return;
        _disposed = true;
        if (Handle != IntPtr.Zero) {
            DestroyHandle();
        }
        if (_memDc != IntPtr.Zero) {
            if (_oldBmp != IntPtr.Zero) OverlayNative.SelectObject(_memDc, _oldBmp);
            OverlayNative.DeleteDC(_memDc);
            _memDc = IntPtr.Zero;
        }
        if (_dib != IntPtr.Zero) {
            OverlayNative.DeleteObject(_dib);
            _dib = IntPtr.Zero;
        }
    }
}

public sealed class LayeredCursorWindow : NativeWindow, IDisposable {
    public const int WinW = 320;
    public const int WinH = 110;
    public const int HotspotX = 28;
    public const int HotspotY = 28;

    private IntPtr _memDc;
    private IntPtr _currentBmp;
    private IntPtr _oldBmp;
    private bool _visible;
    private bool _disposed;

    public LayeredCursorWindow() {
        CreateParams cp = new CreateParams();
        cp.Caption = "OcuCursorOverlay";
        cp.Style = OverlayNative.WS_POPUP;
        cp.ExStyle = OverlayNative.WS_EX_LAYERED | OverlayNative.WS_EX_TRANSPARENT |
                     OverlayNative.WS_EX_TOPMOST | OverlayNative.WS_EX_TOOLWINDOW |
                     OverlayNative.WS_EX_NOACTIVATE;
        cp.X = 0;
        cp.Y = 0;
        cp.Width = WinW;
        cp.Height = WinH;
        CreateHandle(cp);

        OverlayNative.SetWindowDisplayAffinity(Handle, OverlayNative.WDA_EXCLUDEFROMCAPTURE);

        IntPtr screenDc = OverlayNative.GetDC(IntPtr.Zero);
        try {
            _memDc = OverlayNative.CreateCompatibleDC(screenDc);
        } finally {
            OverlayNative.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    public void Show() {
        if (!_visible && Handle != IntPtr.Zero) {
            OverlayNative.ShowWindow(Handle, OverlayNative.SW_SHOWNOACTIVATE);
            _visible = true;
        }
    }

    public void Hide() {
        if (_visible && Handle != IntPtr.Zero) {
            OverlayNative.ShowWindow(Handle, OverlayNative.SW_HIDE);
            _visible = false;
        }
    }

    public void RedrawBitmap(string label, float rippleProgress) {
        if (_disposed || _memDc == IntPtr.Zero) return;

        using (Bitmap bmp = new Bitmap(WinW, WinH, PixelFormat.Format32bppPArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.FromArgb(0, 0, 0, 0));

            if (rippleProgress >= 0f && rippleProgress < 1f) {
                float radius = 6f + 20f * rippleProgress;
                int ringAlpha = (int)((1f - rippleProgress) * 210f);
                using (Pen ringPen = new Pen(Color.FromArgb(ringAlpha, 34, 211, 238), 2.5f)) {
                    g.DrawEllipse(ringPen, HotspotX - radius, HotspotY - radius, radius * 2f, radius * 2f);
                }
            }

            PointF[] arrow = new PointF[] {
                new PointF(HotspotX, HotspotY),
                new PointF(HotspotX, HotspotY + 26f),
                new PointF(HotspotX + 6.5f, HotspotY + 19.5f),
                new PointF(HotspotX + 12.5f, HotspotY + 30f),
                new PointF(HotspotX + 16.5f, HotspotY + 28f),
                new PointF(HotspotX + 10.5f, HotspotY + 17.5f),
                new PointF(HotspotX + 19.5f, HotspotY + 16.5f)
            };

            using (GraphicsPath path = new GraphicsPath()) {
                path.AddPolygon(arrow);
                using (LinearGradientBrush fill = new LinearGradientBrush(
                    new PointF(HotspotX, HotspotY),
                    new PointF(HotspotX + 20f, HotspotY + 30f),
                    Color.FromArgb(245, 79, 70, 229),
                    Color.FromArgb(245, 6, 182, 212))) {
                    g.FillPath(fill, path);
                }
                using (Pen border = new Pen(Color.FromArgb(245, 255, 255, 255), 1.9f)) {
                    border.LineJoin = LineJoin.Round;
                    g.DrawPath(border, path);
                }
            }

            if (!string.IsNullOrEmpty(label)) {
                string clipped = label.Length > 22 ? label.Substring(0, 21) + "..." : label;
                using (Font font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Bold)) {
                    SizeF textSize = g.MeasureString(clipped, font, 240);
                    float pillX = 48f;
                    float pillY = 44f;
                    float pillW = Math.Min(WinW - pillX - 4f, textSize.Width + 20f);
                    float pillH = Math.Max(26f, textSize.Height + 10f);
                    float r = 12f;

                    using (GraphicsPath pill = new GraphicsPath()) {
                        pill.AddArc(pillX, pillY, r, r, 180, 90);
                        pill.AddArc(pillX + pillW - r, pillY, r, r, 270, 90);
                        pill.AddArc(pillX + pillW - r, pillY + pillH - r, r, r, 0, 90);
                        pill.AddArc(pillX, pillY + pillH - r, r, r, 90, 90);
                        pill.CloseFigure();

                        using (SolidBrush bg = new SolidBrush(Color.FromArgb(215, 15, 23, 42))) {
                            g.FillPath(bg, pill);
                        }
                        using (Pen edge = new Pen(Color.FromArgb(170, 56, 189, 248), 1.2f)) {
                            g.DrawPath(edge, pill);
                        }
                    }

                    using (SolidBrush txtBrush = new SolidBrush(Color.FromArgb(250, 248, 250, 252))) {
                        g.DrawString(clipped, font, txtBrush, pillX + 10f, pillY + 5f);
                    }
                }
            }

            IntPtr newBmp = bmp.GetHbitmap(Color.FromArgb(0));
            IntPtr old = OverlayNative.SelectObject(_memDc, newBmp);
            if (_oldBmp == IntPtr.Zero) {
                _oldBmp = old;
            }
            if (_currentBmp != IntPtr.Zero) {
                OverlayNative.DeleteObject(_currentBmp);
            }
            _currentBmp = newBmp;
        }
    }

    public void Present(int screenX, int screenY, byte constAlpha) {
        if (_disposed || Handle == IntPtr.Zero || _currentBmp == IntPtr.Zero) return;
        Show();
        OverlayNative.POINT dst = new OverlayNative.POINT { X = screenX - HotspotX, Y = screenY - HotspotY };
        OverlayNative.SIZE sz = new OverlayNative.SIZE { Width = WinW, Height = WinH };
        OverlayNative.POINT src = new OverlayNative.POINT { X = 0, Y = 0 };
        OverlayNative.BLENDFUNCTION blend = new OverlayNative.BLENDFUNCTION {
            BlendOp = 0,
            BlendFlags = 0,
            SourceConstantAlpha = constAlpha,
            AlphaFormat = 1
        };
        OverlayNative.UpdateLayeredWindow(Handle, IntPtr.Zero, ref dst, ref sz, _memDc, ref src, 0, ref blend, OverlayNative.ULW_ALPHA);
    }

    public void Dispose() {
        if (_disposed) return;
        _disposed = true;
        if (Handle != IntPtr.Zero) {
            DestroyHandle();
        }
        if (_memDc != IntPtr.Zero) {
            if (_oldBmp != IntPtr.Zero) OverlayNative.SelectObject(_memDc, _oldBmp);
            OverlayNative.DeleteDC(_memDc);
            _memDc = IntPtr.Zero;
        }
        if (_currentBmp != IntPtr.Zero) {
            OverlayNative.DeleteObject(_currentBmp);
            _currentBmp = IntPtr.Zero;
        }
    }
}

public sealed class OverlayEngine : IDisposable {
    private sealed class OverlayCommand {
        public string Kind;
        public int Pid;
        public int RelX;
        public int RelY;
        public string Label;
    }

    private readonly int _screenW;
    private readonly int _screenH;
    private readonly int _idleHideMs;
    private readonly int _maxAlpha;
    private readonly int _thickness = 14;

    private readonly LayeredStripWindow _top;
    private readonly LayeredStripWindow _bottom;
    private readonly LayeredStripWindow _left;
    private readonly LayeredStripWindow _right;
    private readonly LayeredCursorWindow _cursor;

    private readonly ConcurrentQueue<OverlayCommand> _queue = new ConcurrentQueue<OverlayCommand>();
    private readonly Stopwatch _sw = Stopwatch.StartNew();
    private readonly System.Windows.Forms.Timer _timer;
    private volatile bool _exiting = false;

    private float _fade = 0f;
    private float _fadeTarget = 0f;
    private long _lastActivityMs = 0;

    private float _curX;
    private float _curY;
    private float _startX;
    private float _startY;
    private float _targetX;
    private float _targetY;
    private long _moveStartMs = 0;
    private long _moveDurationMs = 120;
    private bool _cursorHasPosition = false;

    private long _rippleStartMs = -10000;
    private string _label = "";
    private bool _bitmapDirty = true;

    public OverlayEngine(int idleHideMs, int maxAlpha) {
        OverlayNative.EnsureDpiAware();
        _screenW = Math.Max(320, OverlayNative.GetSystemMetrics(0));
        _screenH = Math.Max(240, OverlayNative.GetSystemMetrics(1));
        _idleHideMs = Math.Max(1000, idleHideMs);
        _maxAlpha = (int)Clamp((float)maxAlpha, 16f, 220f);

        _curX = _screenW * 0.5f;
        _curY = _screenH * 0.5f;
        _startX = _curX;
        _startY = _curY;
        _targetX = _curX;
        _targetY = _curY;

        _top = new LayeredStripWindow(0, 0, _screenW, _thickness);
        _bottom = new LayeredStripWindow(0, _screenH - _thickness, _screenW, _thickness);
        _left = new LayeredStripWindow(0, _thickness, _thickness, Math.Max(1, _screenH - 2 * _thickness));
        _right = new LayeredStripWindow(_screenW - _thickness, _thickness, _thickness, Math.Max(1, _screenH - 2 * _thickness));
        _cursor = new LayeredCursorWindow();

        _timer = new System.Windows.Forms.Timer();
        _timer.Interval = 25;
        _timer.Tick += OnTick;
        _timer.Start();
    }

    private static float Clamp(float v, float lo, float hi) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    public void StartStdinReader() {
        Thread t = new Thread(() => {
            try {
                string line;
                while ((line = Console.In.ReadLine()) != null) {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    string[] parts = line.Split('\t');
                    string cmd = parts[0].Trim().ToUpperInvariant();
                    if (cmd == "EXIT") {
                        _queue.Enqueue(new OverlayCommand { Kind = "EXIT" });
                        break;
                    }
                    if (cmd == "HIDE") {
                        _queue.Enqueue(new OverlayCommand { Kind = "HIDE" });
                        continue;
                    }
                    if (cmd == "STATUS") {
                        int pid = parts.Length > 1 ? ParseInt(parts[1], 0) : 0;
                        string lbl = parts.Length > 2 ? parts[2] : "";
                        _queue.Enqueue(new OverlayCommand { Kind = "STATUS", Pid = pid, Label = lbl });
                        continue;
                    }
                    if (cmd == "MOVE" || cmd == "CLICK") {
                        int pid = parts.Length > 1 ? ParseInt(parts[1], 0) : 0;
                        int rx = parts.Length > 2 ? ParseInt(parts[2], 0) : 0;
                        int ry = parts.Length > 3 ? ParseInt(parts[3], 0) : 0;
                        string lbl = parts.Length > 4 ? parts[4] : "";
                        _queue.Enqueue(new OverlayCommand { Kind = cmd, Pid = pid, RelX = rx, RelY = ry, Label = lbl });
                    }
                }
            } catch {
                // Ignore stdin teardown errors.
            }
            _queue.Enqueue(new OverlayCommand { Kind = "EXIT" });
        });
        t.IsBackground = true;
        t.Start();
    }

    private static int ParseInt(string s, int fallback) {
        int val;
        return int.TryParse(s, out val) ? val : fallback;
    }

    private void ProcessCommands() {
        long now = _sw.ElapsedMilliseconds;
        OverlayCommand cmd;
        while (_queue.TryDequeue(out cmd)) {
            if (cmd.Kind == "EXIT") {
                _exiting = true;
                _timer.Stop();
                Dispose();
                Application.ExitThread();
                return;
            }
            if (cmd.Kind == "HIDE") {
                _fadeTarget = 0f;
                continue;
            }

            _lastActivityMs = now;
            _fadeTarget = 1f;
            if ((cmd.Label ?? "") != _label) {
                _label = cmd.Label ?? "";
                _bitmapDirty = true;
            }

            if (cmd.Kind == "STATUS") {
                if (!_cursorHasPosition) {
                    OverlayNative.RECT r;
                    if (OverlayNative.FindWindowRectByPid(cmd.Pid, out r)) {
                        _curX = _targetX = (r.Left + r.Right) * 0.5f;
                        _curY = _targetY = r.Top + Math.Min(120f, Math.Max(40f, (r.Bottom - r.Top) * 0.15f));
                    } else {
                        _curX = _targetX = Math.Max(60f, _screenW - 340f);
                        _curY = _targetY = 80f;
                    }
                    _startX = _curX;
                    _startY = _curY;
                    _cursorHasPosition = true;
                }
                continue;
            }

            if (cmd.Kind == "MOVE" || cmd.Kind == "CLICK") {
                float sx = cmd.RelX;
                float sy = cmd.RelY;
                OverlayNative.RECT winRect;
                if (cmd.Pid > 0 && OverlayNative.FindWindowRectByPid(cmd.Pid, out winRect)) {
                    sx = winRect.Left + cmd.RelX;
                    sy = winRect.Top + cmd.RelY;
                }
                sx = Clamp(sx, 8f, _screenW - 8f);
                sy = Clamp(sy, 8f, _screenH - 8f);

                _startX = _curX;
                _startY = _curY;
                _targetX = sx;
                _targetY = sy;
                _moveStartMs = now;
                _cursorHasPosition = true;

                if (cmd.Kind == "CLICK") {
                    _rippleStartMs = now;
                    _bitmapDirty = true;
                }
            }
        }
    }

    private void OnTick(object sender, EventArgs e) {
        if (_exiting) return;
        ProcessCommands();
        if (_exiting) return;

        long now = _sw.ElapsedMilliseconds;
        if (_fadeTarget > 0f && (now - _lastActivityMs) > _idleHideMs) {
            _fadeTarget = 0f;
        }

        float step = _fadeTarget > _fade ? 0.14f : 0.06f;
        if (_fade < _fadeTarget) _fade = Math.Min(_fadeTarget, _fade + step);
        else if (_fade > _fadeTarget) _fade = Math.Max(_fadeTarget, _fade - step);

        if (_fade <= 0.005f && _fadeTarget <= 0f) {
            _top.Hide();
            _bottom.Hide();
            _left.Hide();
            _right.Hide();
            _cursor.Hide();
            return;
        }

        if (_cursorHasPosition) {
            float mt = Clamp((float)(now - _moveStartMs) / _moveDurationMs, 0f, 1f);
            float ease = 1f - (float)Math.Pow(1.0 - mt, 3.0);
            _curX = _startX + (_targetX - _startX) * ease;
            _curY = _startY + (_targetY - _startY) * ease;
        }

        float rippleElapsed = (float)(now - _rippleStartMs);
        float rippleProgress = (rippleElapsed >= 0f && rippleElapsed <= 450f) ? (rippleElapsed / 450f) : -1f;
        if (rippleProgress >= 0f || _bitmapDirty) {
            _cursor.RedrawBitmap(_label, rippleProgress);
            _bitmapDirty = rippleProgress >= 0f;
        }

        double phase = (now % 3200L) / 3200.0;
        RenderEdgeStrips(phase);

        byte constAlpha = (byte)Clamp((float)Math.Round(_fade * 255f), 0f, 255f);
        _top.Present(constAlpha);
        _bottom.Present(constAlpha);
        _left.Present(constAlpha);
        _right.Present(constAlpha);
        if (_cursorHasPosition) {
            _cursor.Present((int)Math.Round(_curX), (int)Math.Round(_curY), constAlpha);
        }
    }

    private int SampleAuroraPixel(double u, int distFromEdge, double phase) {
        double dNorm = (double)distFromEdge / _thickness;
        double falloff = Math.Pow(1.0 - dNorm, 1.85);
        double wave = 0.55 + 0.45 * Math.Sin(2.0 * Math.PI * (u * 2.0 - phase));
        int a = (int)Clamp((float)Math.Round(_maxAlpha * falloff * wave), 0f, 255f);
        if (a <= 0) return 0;

        double t = (u + phase) % 1.0;
        if (t < 0) t += 1.0;

        // 4 smooth aurora stops: Cyan -> Indigo -> Violet -> Teal -> Cyan
        double[] rs = { 56, 99, 168, 45, 56 };
        double[] gs = { 189, 102, 85, 212, 189 };
        double[] bs = { 248, 241, 247, 191, 248 };

        double scaled = t * 4.0;
        int idx = Math.Min(3, (int)Math.Floor(scaled));
        double frac = scaled - idx;
        double mu = 0.5 - 0.5 * Math.Cos(frac * Math.PI);

        int r = (int)Math.Round((rs[idx] + (rs[idx + 1] - rs[idx]) * mu) * a / 255.0);
        int g = (int)Math.Round((gs[idx] + (gs[idx + 1] - gs[idx]) * mu) * a / 255.0);
        int b = (int)Math.Round((bs[idx] + (bs[idx + 1] - bs[idx]) * mu) * a / 255.0);

        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    private void RenderEdgeStrips(double phase) {
        double perim = 2.0 * (_screenW + _screenH);

        for (int y = 0; y < _top.WinH; y++) {
            int rowOff = y * _top.WinW;
            for (int x = 0; x < _top.WinW; x++) {
                double u = x / perim;
                _top.Pixels[rowOff + x] = SampleAuroraPixel(u, y, phase);
            }
        }

        for (int x = 0; x < _right.WinW; x++) {
            int dist = (_right.WinW - 1) - x;
            for (int y = 0; y < _right.WinH; y++) {
                double u = (_screenW + _thickness + y) / perim;
                _right.Pixels[y * _right.WinW + x] = SampleAuroraPixel(u, dist, phase);
            }
        }

        for (int y = 0; y < _bottom.WinH; y++) {
            int dist = (_bottom.WinH - 1) - y;
            int rowOff = y * _bottom.WinW;
            for (int x = 0; x < _bottom.WinW; x++) {
                double u = (_screenW + _screenH + (_screenW - 1 - x)) / perim;
                _bottom.Pixels[rowOff + x] = SampleAuroraPixel(u, dist, phase);
            }
        }

        for (int x = 0; x < _left.WinW; x++) {
            for (int y = 0; y < _left.WinH; y++) {
                double u = (2.0 * _screenW + _screenH + (_screenH - _thickness - 1 - y)) / perim;
                _left.Pixels[y * _left.WinW + x] = SampleAuroraPixel(u, x, phase);
            }
        }
    }

    public void Dispose() {
        _top.Dispose();
        _bottom.Dispose();
        _left.Dispose();
        _right.Dispose();
        _cursor.Dispose();
    }
}
"@

Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.Windows.Forms, System.Drawing

$engine = New-Object OverlayEngine($IdleHideMs, $MaxAlpha)
$engine.StartStdinReader()
[Console]::Out.WriteLine("READY")
[Console]::Out.Flush()
[System.Windows.Forms.Application]::Run()
