using Playnite.Common;
using Playnite.Controls;
using Playnite.FullscreenApp.Controls;
using Playnite.Windows;
using System;
using System.Windows;
using System.Windows.Controls;
using System.Xml.Linq;

namespace Playnite.FullscreenApp.Windows
{
    public class MoreGamesWindowFactory : WindowFactory
    {
        public override WindowBase CreateNewWindowInstance()
        {
            return new MoreGamesWindow();
        }
    }

    /// <summary>
    /// Interaction logic for MoreGamesWindow.xaml
    /// </summary>
    public partial class MoreGamesWindow : WindowBase
    {
        public MoreGamesWindow() : base()
        {
            InitializeComponent();
            WindowTools.ConfigureChildWindow(this);
            // 3.5% margin on every side, same ratio as the horizontal list side margins.
            PanelBorder.Margin = new Thickness(GridMain.Width * 0.035);

            XNamespace pns = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
            ListMoreGames.ItemsPanel = Xaml.FromString<ItemsPanelTemplate>(new XDocument(
                new XElement(pns + nameof(ItemsPanelTemplate),
                    new XElement(pns + nameof(FullscreenTilePanel),
                        new XAttribute(nameof(FullscreenTilePanel.Rows), "{Settings Fullscreen.Rows}"),
                        new XAttribute(nameof(FullscreenTilePanel.Columns), "{Settings Fullscreen.MoreGamesColumns}"),
                        new XAttribute(nameof(FullscreenTilePanel.UseHorizontalLayout), "False"),
                        new XAttribute(nameof(FullscreenTilePanel.ItemAspectRatio), "{Settings CoverAspectRatio}"),
                        new XAttribute(nameof(FullscreenTilePanel.ItemSpacing), "{Settings FullscreenItemSpacing}"),
                        new XAttribute(nameof(FullscreenTilePanel.SmoothScrollEnabled), "{Settings Fullscreen.SmoothScrolling}")))
            ).ToString());

            ListMoreGames.ItemTemplate = Xaml.FromString<DataTemplate>(new XDocument(
                new XElement(pns + nameof(DataTemplate),
                    new XElement(pns + nameof(GameListItem),
                        new XAttribute(nameof(GameListItem.Style), "{StaticResource ListGameItemTemplate}")))
            ).ToString());

            ListMoreGames.SetResourceReference(ItemsControl.ItemContainerStyleProperty, "ListGameItemStyle");
        }
    }
}
