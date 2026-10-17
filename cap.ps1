using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Cap {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}

public static class Program {
    public static int Main(string[] args) {
        Cap.SetProcessDPIAware();
        int pid = int.Parse(args[0]);
        string outPath = args[1];

        var proc = System.Diagnostics.Process.GetProcessById(pid);
        var handle = proc.MainWindowHandle;
        if (handle == IntPtr.Zero) { Console.WriteLine("aucune fenetre"); return 1; }

        Cap.SetForegroundWindow(handle);
        System.Threading.Thread.Sleep(700);

        Cap.RECT r;
        Cap.GetWindowRect(handle, out r);
        int w = r.R - r.L, h = r.B - r.T;
        Console.WriteLine(string.Format("fenetre {0}x{1}", w, h));

        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            Cap.PrintWindow(handle, hdc, 2);
            g.ReleaseHdc(hdc);
            bmp.Save(outPath, ImageFormat.Png);
        }
        Console.WriteLine(string.Format("capture : {0} ({1}x{2})", outPath, w, h));
        return 0;
    }
}
