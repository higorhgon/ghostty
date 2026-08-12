using Microsoft.Windows.ApplicationModel.DynamicDependency;

namespace GhosttyTabHost;

static class Program
{
    /// <summary>
    ///  The main entry point for the application.
    /// </summary>
    [STAThread]
    static void Main()
    {
        var logPath = Path.Combine(Path.GetTempPath(), "tabhost_debug.log");
        void Log(string msg) => File.AppendAllText(logPath, $"{DateTime.Now:HH:mm:ss.fff} [Program] {msg}\n");

        // 1.8 encoded as 0x00010008 (major=1, minor=8), matching the
        // Microsoft.WindowsAppSDK NuGet package version referenced below.
        var ok = Bootstrap.TryInitialize(0x00010008, out var hresult);
        Log($"Bootstrap.TryInitialize ok={ok} hresult=0x{hresult:X8}");

        // To customize application configuration such as set high DPI settings or default font,
        // see https://aka.ms/applicationconfiguration.
        ApplicationConfiguration.Initialize();
        Application.Run(new Form1());

        if (ok) Bootstrap.Shutdown();
    }
}