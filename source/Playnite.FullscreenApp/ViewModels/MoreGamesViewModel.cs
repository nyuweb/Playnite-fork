using Playnite.Common;
using Playnite.SDK;
using Playnite.ViewModels;
using Playnite.Windows;
using System;
using System.Collections.Generic;
using System.ComponentModel;

namespace Playnite.FullscreenApp.ViewModels
{
    /// <summary>
    /// Grid with all games of the current filter preset, opened from the "More" tile of the horizontal list.
    /// </summary>
    public class MoreGamesViewModel : ObservableObject
    {
        private readonly IWindowFactory window;
        public FullscreenAppViewModel MainModel { get; }

        public ICollectionView Games => MainModel.GamesView.CollectionView;
        public string Title => MainModel.ActiveFilterPreset?.Name;

        private GamesCollectionViewEntry selectedGame;
        public GamesCollectionViewEntry SelectedGame
        {
            get => selectedGame;
            set
            {
                selectedGame = value;
                OnPropertyChanged();
            }
        }

        public RelayCommand CloseCommand => new RelayCommand(() => Close());

        public RelayCommand<object> ActivateCommand => new RelayCommand<object>((a) =>
        {
            if (SelectedGame != null)
            {
                MainModel.SelectedGame = SelectedGame;
                MainModel.ActivateSelectedCommand.Execute(a);
            }
        });

        public RelayCommand<object> OpenGameMenuCommand => new RelayCommand<object>((a) =>
        {
            if (SelectedGame != null)
            {
                MainModel.SelectedGame = SelectedGame;
                MainModel.OpenGameMenu();
            }
        });

        public MoreGamesViewModel(IWindowFactory window, FullscreenAppViewModel mainModel)
        {
            this.window = window;
            MainModel = mainModel;
            SelectedGame = mainModel.SelectedGame;
        }

        public bool? OpenView()
        {
            return window.CreateAndOpenDialog(this);
        }

        public void Close()
        {
            window.Close(true);
        }
    }
}
