using System.Collections.Generic;
using System.Linq;

namespace Playnite.DesktopApp.ViewModels
{
    public partial class GameEditViewModel
    {
        public class DisplayChoice
        {
            public int Value { get; set; }
            public string Label { get; set; }
        }

        public class ResolutionChoice
        {
            public int Width { get; set; }
            public int Height { get; set; }
            public string Label { get; set; }
        }

        // Empty first entry means "not set" (stored as 0).
        public List<ResolutionChoice> ResolutionChoices { get; } = new List<ResolutionChoice>
        {
            new ResolutionChoice { Width = 0, Height = 0, Label = "" },
            new ResolutionChoice { Width = 3840, Height = 2160, Label = "3840x2160" },
            new ResolutionChoice { Width = 2560, Height = 1440, Label = "2560x1440" },
            new ResolutionChoice { Width = 1920, Height = 1080, Label = "1920x1080" },
            new ResolutionChoice { Width = 1280, Height = 720, Label = "1280x720" },
            new ResolutionChoice { Width = 1024, Height = 768, Label = "1024x768" },
            new ResolutionChoice { Width = 800, Height = 600, Label = "800x600" },
            new ResolutionChoice { Width = 720, Height = 480, Label = "720x480" },
            new ResolutionChoice { Width = 640, Height = 480, Label = "640x480" }
        };

        public List<DisplayChoice> FrequencyChoices { get; } = new List<DisplayChoice>
        {
            new DisplayChoice { Value = 0, Label = "" },
            new DisplayChoice { Value = 30, Label = "30 Hz" },
            new DisplayChoice { Value = 60, Label = "60 Hz" },
            new DisplayChoice { Value = 120, Label = "120 Hz" }
        };

        public ResolutionChoice EditingResolution
        {
            get => ResolutionChoices.FirstOrDefault(a => a.Width == EditingGame.ResolutionWidth && a.Height == EditingGame.ResolutionHeight);
            set
            {
                EditingGame.ResolutionWidth = value?.Width ?? 0;
                EditingGame.ResolutionHeight = value?.Height ?? 0;
            }
        }
    }
}
