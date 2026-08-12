using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Windows.Graphics;

namespace GhosttyTabHost;

public partial class Form1 : Form
{
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "tabhost_debug.log");

    private static void Log(string msg)
    {
        File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {msg}\n");
    }

    private DispatcherQueueController? _dispatcherQueueController;
    private WindowsXamlManager? _xamlManager;
    private DesktopWindowXamlSource? _xamlSource;
    private TabView? _tabView;

    public Form1()
    {
        Log($"Form1 ctor start, ClientSize={ClientSize}");
        InitializeComponent();
        Log($"After InitializeComponent, ClientSize={ClientSize}, Handle={Handle}");
        InitializeXaml();
        Resize += (s, e) =>
        {
            Log($"Resize event, ClientSize={ClientSize}");
            LayoutIsland();
        };
        Shown += (s, e) =>
        {
            Log($"Shown event, ClientSize={ClientSize}");
            LayoutIsland();
        };
    }

    private void InitializeXaml()
    {
        try
        {
            _dispatcherQueueController = DispatcherQueueController.CreateOnCurrentThread();
            Log("DispatcherQueueController created");
            if (Microsoft.UI.Xaml.Application.Current == null)
            {
                _ = new MinimalApp();
            }
            Log($"Application.Current={Microsoft.UI.Xaml.Application.Current}");
            _xamlManager = WindowsXamlManager.InitializeForCurrentThread();
            Log("WindowsXamlManager initialized");
            _xamlSource = new DesktopWindowXamlSource();
            Log("DesktopWindowXamlSource created");

            var windowId = Win32Interop.GetWindowIdFromWindow(Handle);
            Log($"WindowId={windowId.Value}");
            _xamlSource.Initialize(windowId);
            Log($"Initialize() done, SiteBridge={_xamlSource.SiteBridge}");

            _tabView = new TabView
            {
                HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Stretch,
                VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Stretch,
                TabWidthMode = TabViewWidthMode.Equal,
            };
            Log($"TabView default style: {_tabView.Style}, ActualWidth/Height before layout: {_tabView.ActualWidth}/{_tabView.ActualHeight}");
            _tabView.TabItems.Add(new TabViewItem { Header = "Tab 1", Content = new Microsoft.UI.Xaml.Controls.Grid() });
            _tabView.TabItems.Add(new TabViewItem { Header = "Tab 2", Content = new Microsoft.UI.Xaml.Controls.Grid() });
            _tabView.AddTabButtonClick += (s, e) =>
            {
                _tabView.TabItems.Add(new TabViewItem { Header = "New Tab", Content = new Microsoft.UI.Xaml.Controls.Grid() });
            };
            _xamlSource.Content = _tabView;
            Log($"Content set, TabItems.Count={_tabView.TabItems.Count}, resolved style after adding to tree: {_tabView.Style}");

            LayoutIsland();
        }
        catch (Exception ex)
        {
            Log($"EXCEPTION: {ex}");
        }
    }

    private void LayoutIsland()
    {
        if (_xamlSource?.SiteBridge == null)
        {
            Log("LayoutIsland: SiteBridge is null, skipping");
            return;
        }
        var rect = new RectInt32(0, 0, ClientSize.Width, ClientSize.Height);
        Log($"LayoutIsland: MoveAndResize({rect.X},{rect.Y},{rect.Width},{rect.Height})");
        try
        {
            _xamlSource.SiteBridge.MoveAndResize(rect);
            Log($"LayoutIsland: MoveAndResize succeeded, TabView ActualWidth/Height={_tabView?.ActualWidth}/{_tabView?.ActualHeight} DesiredSize={_tabView?.DesiredSize}");
        }
        catch (Exception ex)
        {
            Log($"LayoutIsland EXCEPTION: {ex}");
        }
    }
}
