using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

public static class FrameflowWindow {
    public const string AppId = "Zhizhiniao.FrameFlow";
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey {
        public Guid format; public uint id;
        public PropertyKey(uint id) { format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); this.id = id; }
    }
    [StructLayout(LayoutKind.Explicit, Size = 24)] private struct PropVariant {
        [FieldOffset(0)] public ushort type;
        [FieldOffset(8)] public IntPtr pointer;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }
    private static void SetString(IPropertyStore store, uint id, string text) {
        var key = new PropertyKey(id);
        var value = new PropVariant { type = 31, pointer = Marshal.StringToCoTaskMemUni(text) };
        try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
        finally { PropVariantClear(ref value); }
    }
    public static void ConfigureTaskbar(IntPtr hwnd, string executable, string icon) {
        IPropertyStore store; var iid = typeof(IPropertyStore).GUID;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
        try {
            // Set relaunch metadata before the AppID triggers a taskbar refresh.
            SetString(store, 2, "\"" + executable + "\"");
            SetString(store, 3, icon + ",0");
            SetString(store, 4, "帧流 FrameFlow");
            SetString(store, 5, AppId);
            Marshal.ThrowExceptionForHR(store.Commit());
        } finally { Marshal.ReleaseComObject(store); }
    }
    public static string ReadTaskbarProperty(IntPtr hwnd, uint id) {
        IPropertyStore store; var iid = typeof(IPropertyStore).GUID;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
        var value = new PropVariant();
        try {
            var key = new PropertyKey(id); Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            return value.type == 31 ? Marshal.PtrToStringUni(value.pointer) : null;
        } finally { PropVariantClear(ref value); Marshal.ReleaseComObject(store); }
    }
    public static void ConfigureShortcut(string shortcut) {
        object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        try {
            var file = (System.Runtime.InteropServices.ComTypes.IPersistFile)link;
            file.Load(shortcut, 2);
            var store = (IPropertyStore)link;
            SetString(store, 5, AppId); Marshal.ThrowExceptionForHR(store.Commit());
            file.Save(shortcut, true);
        } finally { Marshal.ReleaseComObject(link); }
    }
}

// Native callbacks write the log; PowerShell and UI code stay on the UI thread.
public static class FrameflowProcess {
    public static Process Start(string fileName, string arguments, string logPath) {
        var gate = new object();
        File.WriteAllText(logPath, "", new UTF8Encoding(false));
        var process = new Process();
        process.StartInfo = new ProcessStartInfo(fileName, arguments) {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        DataReceivedEventHandler append = (sender, e) => {
            if (e.Data == null) return;
            lock (gate) {
                try {
                    using (var stream = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                    using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                        writer.WriteLine(e.Data);
                } catch (IOException) { /* A log-write failure must not crash the downloader UI. */ }
            }
        };
        process.OutputDataReceived += append;
        process.ErrorDataReceived += append;
        try {
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
            return process;
        } catch { process.Dispose(); throw; }
    }
}
