using Playnite.SDK;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace Playnite.FullscreenApp.Controls
{
    /// <summary>
    /// Last tile of the limited horizontal list, opens the grid with all games.
    /// </summary>
    public class MoreGamesItem
    {
        public static MoreGamesItem Instance { get; } = new MoreGamesItem();

        public string DisplayName => ResourceProvider.GetString("LOCMoreGames");

        private MoreGamesItem()
        {
        }
    }

    /// <summary>
    /// First N games of a collection view followed by <see cref="MoreGamesItem"/> if there are more games.
    /// </summary>
    public class LimitedGameList : ObservableCollection<object>, IDisposable
    {
        private readonly ICollectionView source;
        private readonly FullscreenSettings settings;

        public LimitedGameList(ICollectionView source, FullscreenSettings settings)
        {
            this.source = source;
            this.settings = settings;
            source.CollectionChanged += Source_CollectionChanged;
            settings.PropertyChanged += Settings_PropertyChanged;
            Rebuild();
        }

        public void Dispose()
        {
            source.CollectionChanged -= Source_CollectionChanged;
            settings.PropertyChanged -= Settings_PropertyChanged;
        }

        private void Settings_PropertyChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(FullscreenSettings.HorizontalLayoutMaxGames))
            {
                Rebuild();
            }
        }

        private void Source_CollectionChanged(object sender, NotifyCollectionChangedEventArgs e)
        {
            Rebuild();
        }

        private void Rebuild()
        {
            var limit = settings.HorizontalLayoutMaxGames;
            var games = source.Cast<object>().Take(limit + 1).ToList();
            var target = games.Take(limit).ToList();
            if (games.Count > limit)
            {
                target.Add(MoreGamesItem.Instance);
            }

            // Minimal changes only, a full reset would drop the list selection.
            for (int i = 0; i < target.Count; i++)
            {
                if (i < Count && ReferenceEquals(this[i], target[i]))
                {
                    continue;
                }

                var existing = -1;
                for (int j = i + 1; j < Count; j++)
                {
                    if (ReferenceEquals(this[j], target[i]))
                    {
                        existing = j;
                        break;
                    }
                }

                if (existing >= 0)
                {
                    Move(existing, i);
                }
                else
                {
                    Insert(i, target[i]);
                }
            }

            while (Count > target.Count)
            {
                RemoveAt(Count - 1);
            }
        }
    }

    public class GameListTemplateSelector : DataTemplateSelector
    {
        public DataTemplate GameTemplate { get; set; }

        public override DataTemplate SelectTemplate(object item, DependencyObject container)
        {
            if (item is MoreGamesItem)
            {
                return Application.Current.TryFindResource("MoreGamesItemTemplate") as DataTemplate ?? GameTemplate;
            }

            return GameTemplate;
        }
    }

    /// <summary>
    /// Keeps the view model selection untouched when the "More" tile is selected or when
    /// the selected game is not part of the limited list.
    /// </summary>
    public class GameListSelectionConverter : IValueConverter
    {
        private readonly Func<object, bool> isInList;

        public GameListSelectionConverter(Func<object, bool> isInList)
        {
            this.isInList = isInList;
        }

        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value == null || isInList(value))
            {
                return value;
            }

            return Binding.DoNothing;
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            return value is MoreGamesItem ? Binding.DoNothing : value;
        }
    }
}
