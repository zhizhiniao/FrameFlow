using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class WindowCapture {
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static void Save(IntPtr hwnd, string path) {
        IntPtr previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
        Rect rect;
        if (!GetWindowRect(hwnd, out rect)) throw new Exception("Cannot locate test window");
        using (var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                IntPtr hdc = graphics.GetHdc();
                try { if (!PrintWindow(hwnd, hdc, 2)) throw new Exception("PrintWindow failed"); }
                finally { graphics.ReleaseHdc(hdc); }
            }
            bitmap.Save(path, ImageFormat.Png);
        }
        } finally { if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi); }
    }
}
