using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using NUnit.Framework;
using Playnite.Common;

namespace Playnite.Tests
{
    [TestFixture]
    public class ProcessExitWaiterTests
    {
        private static Process StartPing(int count)
        {
            return Process.Start(new ProcessStartInfo("ping", $"-n {count} 127.0.0.1")
            {
                CreateNoWindow = true,
                UseShellExecute = false
            });
        }

        private static void Kill(Process proc)
        {
            try
            {
                if (!proc.HasExited)
                {
                    proc.Kill();
                }
            }
            catch
            {
            }

            proc.Dispose();
        }

        [Test]
        public async Task WakesEarlyWhenWatchedProcessExitsTest()
        {
            var proc = StartPing(3);
            try
            {
                var watch = Stopwatch.StartNew();
                var woken = await ProcessExitWaiter.WaitAsync(new[] { proc.Id }, 30_000, CancellationToken.None);
                watch.Stop();
                Assert.IsTrue(woken);
                Assert.Less(watch.ElapsedMilliseconds, 15_000);
            }
            finally
            {
                Kill(proc);
            }
        }

        [Test]
        public async Task TimesOutWhenNothingIsWatchedTest()
        {
            var watch = Stopwatch.StartNew();
            var woken = await ProcessExitWaiter.WaitAsync(null, 400, CancellationToken.None);
            watch.Stop();
            Assert.IsFalse(woken);
            Assert.GreaterOrEqual(watch.ElapsedMilliseconds, 300);
        }

        [Test]
        public async Task TimesOutWhenWatchedProcessKeepsRunningTest()
        {
            var proc = StartPing(60);
            try
            {
                var watch = Stopwatch.StartNew();
                var woken = await ProcessExitWaiter.WaitAsync(new[] { proc.Id }, 500, CancellationToken.None);
                watch.Stop();
                Assert.IsFalse(woken);
                Assert.GreaterOrEqual(watch.ElapsedMilliseconds, 400);
            }
            finally
            {
                Kill(proc);
            }
        }

        [Test]
        public async Task AlreadyExitedProcessWakesImmediatelyTest()
        {
            var proc = StartPing(1);
            var id = proc.Id;
            proc.WaitForExit();
            proc.Dispose();

            var watch = Stopwatch.StartNew();
            var woken = await ProcessExitWaiter.WaitAsync(new[] { id }, 30_000, CancellationToken.None);
            watch.Stop();
            Assert.IsTrue(woken);
            Assert.Less(watch.ElapsedMilliseconds, 10_000);
        }

        [Test]
        public async Task CancellationStopsWaitTest()
        {
            using (var cancel = new CancellationTokenSource(300))
            {
                var watch = Stopwatch.StartNew();
                var woken = await ProcessExitWaiter.WaitAsync(null, 30_000, cancel.Token);
                watch.Stop();
                Assert.IsFalse(woken);
                Assert.Less(watch.ElapsedMilliseconds, 10_000);
            }
        }
    }
}
