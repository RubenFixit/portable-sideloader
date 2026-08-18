using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

// Launcher stub for portable-sideloader.
//
// The PortableApps.com Platform launches executables, never .ps1 files, so this exists for three
// reasons:
//
//   1. It gives the Platform something to put in the menu, and therefore something you can set
//      "Start Automatically" on.
//   2. It applies a staged self-update BEFORE any script is loaded. A running process cannot
//      overwrite its own files, so updates are staged into Data\update\ and swapped in here, at
//      the one moment nothing is holding them open.
//   3. It starts PowerShell with -ExecutionPolicy Bypass, so a .ps1 that arrived from the
//      internet (Mark-of-the-Web) cannot be blocked from running.
//
// Built by build.ps1 with the csc.exe that ships with Windows - no toolchain required.

internal static class Launcher
{
    // With no arguments - which is how the Platform starts it - run the update check. That is the
    // prompt-on-launch behaviour; anything else passed through goes straight to the script.
    private const string DefaultCommand = "update";

    private static int Main(string[] args)
    {
        string exePath = Assembly.GetExecutingAssembly().Location;
        string root = Path.GetDirectoryName(exePath);
        bool launchedBare = args.Length == 0;

        TryQuietly(() => CleanupPreviousStub(root));

        try
        {
            ApplyStagedUpdate(root, exePath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("  ! staged update failed, continuing with current version: " + ex.Message);
        }

        string script = Path.Combine(root, "App", "sideload.ps1");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Cannot find " + script);
            Pause(launchedBare);
            return 2;
        }

        int exitCode = RunScript(script, args);
        Pause(launchedBare);
        return exitCode;
    }

    // A stub replaced on a previous run left itself behind as *.old; Windows would not let it be
    // deleted while it was the running image.
    private static void CleanupPreviousStub(string root)
    {
        foreach (string stale in Directory.GetFiles(root, "*.old"))
        {
            TryQuietly(() => File.Delete(stale));
        }
    }

    private static void ApplyStagedUpdate(string root, string exePath)
    {
        string staging = Path.Combine(root, "Data", "update");
        if (!Directory.Exists(staging)) return;

        string stagedApp = Path.Combine(staging, "App");
        if (Directory.Exists(stagedApp))
        {
            string liveApp = Path.Combine(root, "App");
            string retired = liveApp + ".replaced";

            if (Directory.Exists(retired)) Directory.Delete(retired, true);
            if (Directory.Exists(liveApp)) Directory.Move(liveApp, retired);

            try
            {
                Directory.Move(stagedApp, liveApp);
            }
            catch
            {
                // Put the old one back rather than leaving the install with no code at all.
                if (!Directory.Exists(liveApp) && Directory.Exists(retired)) Directory.Move(retired, liveApp);
                throw;
            }

            TryQuietly(() => Directory.Delete(retired, true));
            Console.WriteLine("  applied staged update to App\\");
        }

        // Loose files at the package root - README, LICENSE, build.ps1 - so an update refreshes
        // everything except the stub, which needs the rename dance below, and Data\, which is
        // yours and must never be overwritten.
        string stubName = Path.GetFileName(exePath);
        foreach (string staged in Directory.GetFiles(staging))
        {
            string name = Path.GetFileName(staged);
            if (string.Equals(name, stubName, StringComparison.OrdinalIgnoreCase)) continue;
            TryQuietly(() => File.Copy(staged, Path.Combine(root, name), true));
        }

        // The stub itself cannot be overwritten while it is running, but it CAN be renamed - so
        // move ourselves aside and drop the new one in. It takes effect on the next launch.
        string stagedStub = Path.Combine(staging, stubName);
        if (File.Exists(stagedStub))
        {
            File.Move(exePath, exePath + ".old");
            File.Copy(stagedStub, exePath, true);
            Console.WriteLine("  new launcher staged; it takes effect next launch");
        }

        TryQuietly(() => Directory.Delete(staging, true));
    }

    private static int RunScript(string script, string[] args)
    {
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script);
        if (args.Length == 0)
        {
            arguments += " " + DefaultCommand;
        }
        else
        {
            foreach (string a in args) arguments += " " + Quote(a);
        }

        ProcessStartInfo psi = new ProcessStartInfo(FindPowerShell(), arguments);
        psi.UseShellExecute = false;
        psi.WorkingDirectory = Path.GetDirectoryName(script);

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    // PowerShell 7 if it is on PATH, otherwise the 5.1 that ships with Windows.
    private static string FindPowerShell()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string exe in new[] { "pwsh.exe", "powershell.exe" })
        {
            foreach (string dir in path.Split(';'))
            {
                if (dir.Length == 0) continue;
                try
                {
                    string candidate = Path.Combine(dir.Trim(), exe);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { /* malformed PATH entry */ }
            }
        }
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
    }

    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    // Started from the Platform there is no parent console, so the window would close before the
    // summary could be read. Started with arguments from a shell, do not get in the way.
    private static void Pause(bool launchedBare)
    {
        if (!launchedBare || Console.IsOutputRedirected) return;
        Console.WriteLine();
        Console.Write("  Press any key to close...");
        try { Console.ReadKey(true); } catch { /* no interactive console */ }
        Console.WriteLine();
    }

    private static void TryQuietly(Action action)
    {
        try { action(); } catch { /* best effort */ }
    }
}
