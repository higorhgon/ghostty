namespace GhosttyTabHost;

/// <summary>
/// A bare-minimum Microsoft.UI.Xaml.Application. XAML-Islands-only hosting
/// (no App.xaml, no Window of our own) still seems to need *some*
/// Application instance to exist for WinUI3's built-in theme/color
/// resources to resolve -- without one, XamlControlsResources itself fails
/// to construct ("Cannot find a resource with the given key:
/// AcrylicBackgroundFillColorDefaultBrush").
/// </summary>
public partial class MinimalApp : Microsoft.UI.Xaml.Application
{
    private static readonly string LogPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tabhost_debug.log");
    private static void Log(string msg) =>
        System.IO.File.AppendAllText(LogPath, $"{System.DateTime.Now:HH:mm:ss.fff} [MinimalApp] {msg}\n");

    public MinimalApp()
    {
        try
        {
            Log("ctor start");
            Resources.MergedDictionaries.Add(new Microsoft.UI.Xaml.Controls.XamlControlsResources());
            Log("XamlControlsResources merged into Application.Resources");
        }
        catch (System.Exception ex)
        {
            Log($"EXCEPTION in MinimalApp ctor: {ex}");
        }
    }
}
