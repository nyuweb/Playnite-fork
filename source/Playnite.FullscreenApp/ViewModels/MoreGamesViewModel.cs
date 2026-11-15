using Playnite.Common;
using Playnite.SDK;
using Playnite.ViewModels;
using Playnite.Windows;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;

namespace Playnite.FullscreenApp.ViewModels
{
    /// <summary>
    /// Grid with all games of the current filter preset, opened from the "More" tile of the horizontal list.
    /// </summary>
    public class MoreGamesViewModel : ObservableObject
    {
        private readonly IWindowFactory window;
        public FullscreenAppViewModel MainModel { get; }

        // Games already shown in the horizontal list are not repeated here.
        public List<GamesCollectionViewEntry> Games { get; }
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
                // Launch only after the modal window is fully closed, same as launching from the main list.
                var game = SelectedGame;
                pendingAction = () =>
                {
                    MainModel.SelectedGame = game;
                    MainModel.ActivateSelectedCommand.Execute(a);
                };

                Close();
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

        private Action pendingAction;

        public void RunPendingAction()
        {
            var action = pendingAction;
            pendingAction = null;
            action?.Invoke();
        }

        public MoreGamesViewModel(IWindowFactory window, FullscreenAppViewModel mainModel)
        {
            this.window = window;
            MainModel = mainModel;
            Games = mainModel.GamesView.CollectionView
                .Cast<GamesCollectionViewEntry>()
                .Skip(mainModel.AppSettings.Fullscreen.HorizontalLayoutMaxGames)
                .ToList();
            SelectedGame = Games.Contains(mainModel.SelectedGame) ? mainModel.SelectedGame : Games.FirstOrDefault();
        }

        public bool? OpenView()
        {
            MainModel.GameStarting += MainModel_GameStarting;
            try
            {
                return window.CreateAndOpenDialog(this);
            }
            finally
            {
                MainModel.GameStarting -= MainModel_GameStarting;
            }
        }

        // The grid is a modal window, it would keep input after the game exits if it stayed open.
        private void MainModel_GameStarting(object sender, EventArgs e)
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(new Action(Close));
        }

        public void Close()
        {
            window.Close(true);
        }
    }
}
