using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

public static class FrameflowWindow {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
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
