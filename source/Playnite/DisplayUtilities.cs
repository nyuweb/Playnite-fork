using Newtonsoft.Json;
using Playnite.Common;
using Playnite.Native;
using Playnite.SDK;
using Playnite.Settings;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace Playnite
{
    public class DisplayInfo
    {
        public string Name { get; set; }
        public string Port { get; set; }
        public bool Active { get; set; }
        public bool Primary { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int X { get; set; }
        public int Y { get; set; }

        [JsonIgnore]
        public string Label => string.IsNullOrEmpty(Port) ? Name : $"{Name} ({Port})";
    }

    public static class DisplayUtilities
    {
        private static readonly ILogger logger = LogManager.GetLogger();
        private static readonly object lockObj = new object();
        private const uint pathActiveFlag = 0x1;
        private static List<DisplayInfo> displays;

        public static string ScreensFilePath => Path.Combine(PlaynitePaths.ConfigRootPath, "screens.json");
        public static string ScriptPath => Path.Combine(PlaynitePaths.ProgramPath, "Scripts", "switch-display.ps1");
        private static string SnapshotPath => Path.Combine(PlaynitePaths.ConfigRootPath, "display-snapshot.json");

        public static List<DisplayInfo> GetDisplays()
        {
            lock (lockObj)
            {
                if (displays == null)
                {
                    Refresh();
                }

                return displays.ToList();
            }
        }

        public static void RefreshAndSave()
        {
            try
            {
                var list = Refresh();
                FileSystem.WriteStringToFile(ScreensFilePath, Serialization.ToJson(list, true));
                logger.Info($"Saved {list.Count} displays to {ScreensFilePath}.");
            }
            catch (Exception e) when (!PlayniteEnvironment.ThrowAllErrors)
            {
                logger.Error(e, "Failed to save the display list.");
            }
        }

        private static List<DisplayInfo> Refresh()
        {
            lock (lockObj)
            {
                try
                {
                    displays = Enumerate();
                }
                catch (Exception e) when (!PlayniteEnvironment.ThrowAllErrors)
                {
                    logger.Error(e, "Failed to enumerate displays.");
                    displays = new List<DisplayInfo>();
                }

                return displays.ToList();
            }
        }

        private static List<DisplayInfo> Enumerate()
        {
            var result = new Dictionary<string, DisplayInfo>();
            var flags = QUERY_DEVICE_CONFIG_FLAGS.QDC_ALL_PATHS;
            if (User32.GetDisplayConfigBufferSizes(flags, out var pathCount, out var modeCount) != WinError.ERROR_SUCCESS)
            {
                logger.Error("Failed to retrieve display config buffer sizes.");
                return new List<DisplayInfo>();
            }

            var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            if (User32.QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != WinError.ERROR_SUCCESS)
            {
                logger.Error("Failed to retrieve display config.");
                return new List<DisplayInfo>();
            }

            for (int i = 0; i < pathCount; i++)
            {
                var path = paths[i];
                if (!path.targetInfo.targetAvailable)
                {
                    continue;
                }

                var key = $"{path.targetInfo.adapterId.HighPart}:{path.targetInfo.adapterId.LowPart}:{path.targetInfo.id}";
                var active = (path.flags & pathActiveFlag) != 0;
                if (result.TryGetValue(key, out var existing) && (existing.Active || !active))
                {
                    continue;
                }

                var nameInfo = new DISPLAYCONFIG_TARGET_DEVICE_NAME
                {
                    header =
                    {
                        type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
                        adapterId = path.targetInfo.adapterId,
                        id = path.targetInfo.id,
                        size = (uint)Marshal.SizeOf<DISPLAYCONFIG_TARGET_DEVICE_NAME>()
                    }
                };

                if (User32.DisplayConfigGetDeviceInfo(ref nameInfo) != WinError.ERROR_SUCCESS)
                {
                    continue;
                }

                var info = new DisplayInfo
                {
                    Name = string.IsNullOrWhiteSpace(nameInfo.monitorFriendlyDeviceName) ? "Retro4K" : nameInfo.monitorFriendlyDeviceName,
                    Port = GetPortName((uint)nameInfo.outputTechnology),
                    Active = active
                };

                var modeIndex = path.sourceInfo.modeInfoIdx;
                if (active && modeIndex < modes.Length && modes[modeIndex].infoType == DISPLAYCONFIG_MODE_INFO_TYPE.DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE)
                {
                    var source = modes[modeIndex].modeInfo.sourceMode;
                    info.Width = (int)source.width;
                    info.Height = (int)source.height;
                    info.X = source.position.x;
                    info.Y = source.position.y;
                    info.Primary = source.position.x == 0 && source.position.y == 0;
                }

                result[key] = info;
            }

            return result.Values.OrderByDescending(a => a.Primary).ThenBy(a => a.Name).ToList();
        }

        private static string GetPortName(uint outputTechnology)
        {
            switch (outputTechnology)
            {
                case 0: return "VGA";
                case 4: return "DVI";
                case 5: return "HDMI";
                case 10:
                case 11: return "DP";
                case 6:
                case 0x80000000: return "Internal";
                default: return string.Empty;
            }
        }

        /// <summary>
        /// Switches to the given display (others turned off, resolution/frequency applied when above 0,
        /// primary, audio). Returns true if the previous state was saved and <see cref="Restore"/> must be called later.
        /// </summary>
        public static bool SwitchTo(string displayName, int width, int height, int frequency)
        {
            if (!File.Exists(ScriptPath))
            {
                logger.Error($"Display switch script not found: {ScriptPath}");
                return false;
            }

            FileSystem.DeleteFile(SnapshotPath);
            logger.Info($"Switching display to {displayName} ({width}x{height} @ {frequency} Hz).");
            var args = $"-Action Switch -DisplayName {Quote(displayName)} -Width {width} -Height {height} -Hz {frequency} -SnapshotFile {Quote(SnapshotPath)}";
            var exitCode = RunScript(args);
            logger.Info($"Display switch finished with exit code {exitCode}.");
            return File.Exists(SnapshotPath);
        }

        public static void Restore()
        {
            if (!File.Exists(SnapshotPath) || !File.Exists(ScriptPath))
            {
                return;
            }

            logger.Info("Restoring previous display configuration.");
            var exitCode = RunScript($"-Action Restore -SnapshotFile {Quote(SnapshotPath)}");
            logger.Info($"Display restore finished with exit code {exitCode}.");
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
                        logger.Warn("Display script timed out, killing it.");
                        process.Kill();
                        return -1;
                    }

                    return process.ExitCode;
                }
            }
            catch (Exception e) when (!PlayniteEnvironment.ThrowAllErrors)
            {
                logger.Error(e, "Failed to run display script.");
                return -1;
            }
        }
    }
}
