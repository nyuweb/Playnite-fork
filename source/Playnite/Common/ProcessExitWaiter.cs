using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Playnite.Common
{
    /// <summary>
    /// Waits until a timeout elapses, but wakes up earlier when one of the watched processes exits.
    /// Used by game tracking to react to a game being closed without waiting for the next polling tick.
    /// Watching is best effort: processes that can't be watched (for example elevated ones) are simply
    /// covered by the timeout, so callers must still verify the state after this returns.
    /// </summary>
    public static class ProcessExitWaiter
    {
        private const int MaxWatchedProcesses = 32;

        // Minimum pause after an early wake up, so a stale process id can never turn the caller into a busy loop.
        public const int MinWakeGapMs = 250;

        /// <returns>True if woken up by a watched process exit, false if the timeout elapsed or the wait was cancelled.</returns>
        public static async Task<bool> WaitAsync(IEnumerable<int> processIds, int timeoutMs, CancellationToken token)
        {
            var exitSignal = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var watched = new List<Process>();
            try
            {
                if (processIds != null)
                {
                    foreach (var id in processIds.Where(a => a > 0).Distinct().Take(MaxWatchedProcesses))
                    {
                        try
                        {
                            var proc = Process.GetProcessById(id);
                            watched.Add(proc);
                            proc.EnableRaisingEvents = true;
                            proc.Exited += (_, __) => exitSignal.TrySetResult(true);
                            if (proc.HasExited)
                            {
                                exitSignal.TrySetResult(true);
                            }
                        }
                        catch (ArgumentException)
                        {
                            // Process is not running anymore.
                            exitSignal.TrySetResult(true);
                        }
                        catch (Exception)
                        {
                            // Process can't be watched (access denied etc.), regular timeout will cover it.
                        }
                    }
                }

                using (var delayCancel = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    var delay = Task.Delay(timeoutMs, delayCancel.Token);
                    var finished = await Task.WhenAny(delay, exitSignal.Task).ConfigureAwait(false);
                    delayCancel.Cancel();
                    if (finished != exitSignal.Task)
                    {
                        return false;
                    }
                }

                await Task.Delay(MinWakeGapMs, token).ConfigureAwait(false);
                return true;
            }
            catch (OperationCanceledException)
            {
                return false;
            }
            catch (ObjectDisposedException)
            {
                // Cancellation source was disposed while tracking was being stopped.
                return false;
            }
            finally
            {
                foreach (var proc in watched)
                {
                    proc.Dispose();
                }
            }
        }
    }
}
