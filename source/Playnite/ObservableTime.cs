using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Threading;
using Playnite.Common;
using System.Windows;

namespace Playnite
{
    public class ObservableTime : ObservableObject
    {
        private SynchronizationContext context;
        private CancellationTokenSource watcherToken;
        private Task currentTask;

        public string Time
        {
            get => DateTime.Now.ToString(Common.Constants.TimeUiFormat);
        }

        public ObservableTime()
        {
            context = SynchronizationContext.Current;
            if (!DesignerTools.IsInDesignMode)
            {
                StartWatcher();
            }
        }

        public async void StartWatcher()
        {
            watcherToken?.Cancel();
            if (currentTask != null)
            {
                await currentTask;
            }

            watcherToken = new CancellationTokenSource();
            currentTask = Task.Run(async () =>
            {
                while (true)
                {
                    if (watcherToken.IsCancellationRequested)
                    {
                        return;
                    }

                    context.Post((a) => OnPropertyChanged(nameof(Time)), null);
                    // Time is displayed with minute precision, so wake up once per minute, on the minute.
                    var now = DateTime.Now;
                    await Task.Delay(60000 - (now.Second * 1000 + now.Millisecond) + 50);
                }
            }, watcherToken.Token);
        }

        public async void StopWatcher()
        {
            watcherToken?.Cancel();
            if (currentTask != null)
            {
                await currentTask;
            }
        }

        public void Dispose()
        {
            StopWatcher();
        }
    }
}
