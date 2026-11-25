using Playnite.Common;
using Playnite.SDK;
using Playnite.Settings;
using System;
using System.Diagnostics;
using System.IO;

namespace Playnite
{
    public static class DisplayUtilities
    {
        private static readonly ILogger logger = LogManager.GetLogger();

        public static string ScriptPath => Path.Combine(PlaynitePaths.ProgramPath, "Scripts", "set-resolution.ps1");
        private static string SnapshotPath => Path.Combine(PlaynitePaths.ConfigRootPath, "display-snapshot.json");

        /// <summary>
        /// Applies resolution / frequency (when above 0) to the primary display. Returns true if the previous
        /// mode was saved and <see cref="Restore"/> must be called later.
        /// </summary>
        public static bool SetResolution(int width, int height, int frequency)
        {
            if (!File.Exists(ScriptPath))
            {
                logger.Error($"Resolution script not found: {ScriptPath}");
                return false;
            }

            FileSystem.DeleteFile(SnapshotPath);
            logger.Info($"Setting resolution {width}x{height} @ {frequency} Hz.");
            var exitCode = RunScript($"-Action Set -Width {width} -Height {height} -Hz {frequency} -SnapshotFile {Quote(SnapshotPath)}");
            logger.Info($"Resolution change finished with exit code {exitCode}.");
            return File.Exists(SnapshotPath);
        }

        public static void Restore()
        {
            if (!File.Exists(SnapshotPath) || !File.Exists(ScriptPath))
            {
                return;
            }

            logger.Info("Restoring previous resolution.");
            var exitCode = RunScript($"-Action Restore -SnapshotFile {Quote(SnapshotPath)}");
            logger.Info($"Resolution restore finished with exit code {exitCode}.");
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private static int RunScript(string scriptArgs)
        {
            try
            {
                var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                var startInfo = new ProcessStartInfo(powershell, $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {Quote(ScriptPath)} {scriptArgs}")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                using (var process = Process.Start(startInfo))
                {
                    if (!process.WaitForExit(90000))
                    {
                        logger.Warn("Resolution script timed out, killing it.");
                        process.Kill();
                        return -1;
                    }

                    return process.ExitCode;
                }
            }
            catch (Exception e) when (!PlayniteEnvironment.ThrowAllErrors)
            {
                logger.Error(e, "Failed to run resolution script.");
                return -1;
            }
        }
    }
}
