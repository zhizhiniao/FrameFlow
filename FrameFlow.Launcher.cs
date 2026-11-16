using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Security.Principal;

internal static class Launcher {
    [STAThread] static int Main() {
        bool created;
        using (var mutex = new Mutex(true, "Local\\FrameFlow-" + WindowsIdentity.GetCurrent().User.Value, out created)) {
            if (!created) { MessageBox.Show("帧流已经打开，请在任务栏中切换到它。", "帧流"); return 0; }
            try {
                string root = AppDomain.CurrentDomain.BaseDirectory;
                foreach (string file in new [] {"VideoDownloader.ps1", "VideoDownloader.UI.ps1", "VideoDownloader.Queue.ps1", "VideoDownloader.Accounts.ps1", "VideoDownloader.Update.ps1", "Update.Check.ps1", "Update.Apply.ps1", "app-version.json", "FrameFlow.ico", "VideoDownloader.xaml", "VideoDownloader.Runtime.cs", "worker\\FrameFlow.Worker.exe", "browser\\chrome.exe", "yt-dlp.exe", "ffmpeg\\bin\\ffmpeg.exe", "ffmpeg\\bin\\ffprobe.exe"}) {
                    if (!File.Exists(Path.Combine(root, file))) throw new Exception("组件不完整，请将压缩包全部解压到一个文件夹后，再打开 FrameFlow.exe。缺少：" + file);
                }
                string data = Environment.GetEnvironmentVariable("FRAMEFLOW_DATA_ROOT");
                if (String.IsNullOrEmpty(data)) data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FrameFlow");
                data = Path.GetFullPath(data);
                Directory.CreateDirectory(data);
                string temp = Path.Combine(data, "temp");
                if (Directory.Exists(temp)) foreach (string file in Directory.GetFiles(temp, "session-*.txt")) File.Delete(file);
                string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
                var info = new ProcessStartInfo(ps, "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"" + Path.Combine(root, "VideoDownloader.ps1") + "\"");
                info.UseShellExecute = false; info.CreateNoWindow = true;
                info.WorkingDirectory = root;
                info.RedirectStandardError = true;
                using (var process = Process.Start(info)) {
                    string error = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0) {
                        File.WriteAllText(Path.Combine(data, "startup.log"), error);
                        throw new Exception("启动未完成。请确认系统为 Windows 10/11，并已完整解压。诊断文件：" + Path.Combine(data, "startup.log"));
                    }
                }
                return 0;
            } catch (Exception ex) { MessageBox.Show(ex.Message, "帧流 · 启动提示", MessageBoxButtons.OK, MessageBoxIcon.Information); return 1; }
        }
    }
}
