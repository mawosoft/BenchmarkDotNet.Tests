using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Linq;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;

namespace SysManagementVersions
{
#if NET5_0_OR_GREATER
    [SuppressMessage("Interoperability", "CA1416:Validate platform compatibility", Justification = "test only")]
#endif
    internal class Program
    {
        static void Main()
        {
            try
            {
                string self = Assembly.GetExecutingAssembly().Location;
                Stack<string> stack = new(Path.GetDirectoryName(self)!.Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }));
                string relpath = "";
                while (stack.Count > 0 && string.Compare(stack.Peek(), "bin", StringComparison.OrdinalIgnoreCase) != 0)
                {
                    relpath = stack.Pop() + Path.DirectorySeparatorChar + relpath;
                }
                Console.WriteLine("Executing: " + Path.Combine(relpath, Path.GetFileName(self)));
                Console.WriteLine($"Environment Version: {Environment.Version}");
                Console.WriteLine($"Framework Description: {RuntimeInformation.FrameworkDescription}");
                Console.WriteLine("ManagementObjectSearcher contained in:");
                Assembly? assembly = Assembly.GetAssembly(typeof(ManagementObjectSearcher));
                if (assembly != null)
                {
                    Console.WriteLine(assembly.GetName().ToString());
                    Console.WriteLine("  " + assembly.GetName().CodeBase);
                    AssemblyFileVersionAttribute? fileVersion = assembly.GetCustomAttribute<AssemblyFileVersionAttribute>();
                    AssemblyInformationalVersionAttribute? infoVersion = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
                    Console.WriteLine("  File Version: " + fileVersion?.Version + " Informational Version: " + infoVersion?.InformationalVersion);
                }
                Console.WriteLine();
                // MOS calls in BenchmarkDotNet
                // https://github.com/dotnet/BenchmarkDotNet/blob/master/src/BenchmarkDotNet/Portability/Cpu/MosCpuInfoProvider.cs
                bool mosCpuOk = TestManagementObjectSearcher(null, "SELECT * FROM Win32_Processor");
                // GetAntivirusProducts
                // https://github.com/dotnet/BenchmarkDotNet/blob/d312edcbf96ad37586119520ad6b10cbab9a95b2/src/BenchmarkDotNet/Portability/RuntimeInformation.cs#L333
                TestManagementObjectSearcher(@"root\SecurityCenter2", "SELECT * FROM AntiVirusProduct");
                // GetVirtualMachineHypervisor
                // https://github.com/dotnet/BenchmarkDotNet/blob/d312edcbf96ad37586119520ad6b10cbab9a95b2/src/BenchmarkDotNet/Portability/RuntimeInformation.cs#L362
                TestManagementObjectSearcher(null, "Select * from Win32_ComputerSystem");
                if (mosCpuOk)
                {
                    TestGetCpuInfoViaMos1();
                }
                TestGetCpuInfoViaWmic();
            }
            finally
            {
                Console.WriteLine("Press Enter to exit");
                Console.ReadLine();
            }
        }

        static bool TestManagementObjectSearcher(string? scope, string query)
        {
            ManagementObjectSearcher? mos = null;
            bool retVal = false;
            try
            {
                mos = scope == null ? new ManagementObjectSearcher(query) : new ManagementObjectSearcher(scope, query);
                Console.WriteLine($"new ManagementObjectSearcher({(scope == null ? "" : '"' + scope + "\", ")}\"{query}\") {(mos == null ? "returned null" : "succeeded")}");
                retVal = mos != null;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"new ManagementObjectSearcher({(scope == null ? "" : '"' + scope + "\", ")}\"{query}\") failed with exception:");
                Console.WriteLine(ex.Message);
            }
            finally
            {
                mos?.Dispose();
            }
            return retVal;
        }

        internal static class WmicCpuInfoKeyNames
        {
            internal const string NumberOfLogicalProcessors = "NumberOfLogicalProcessors";
            internal const string NumberOfCores = "NumberOfCores";
            internal const string Name = "Name";
            internal const string MaxClockSpeed = "MaxClockSpeed";
        }

        static void TestGetCpuInfoViaMos1()
        {
            HashSet<string> processorModelNames = new();
            uint physicalCoreCount = 0;
            uint logicalCoreCount = 0;
            int processorsCount = 0;
            //uint nominalClockSpeed = 0;
            uint maxClockSpeed = 0;
            //uint minClockSpeed = 0;
            Stopwatch stopwatch = Stopwatch.StartNew();
            using ManagementObjectSearcher mos = new("SELECT * FROM Win32_Processor");
            foreach (ManagementObject moProcessor in mos.Get().Cast<ManagementObject>())
            {
                string? name = moProcessor[WmicCpuInfoKeyNames.Name]?.ToString();
                if (!string.IsNullOrEmpty(name))
                {
                    processorModelNames.Add(name!);
                    processorsCount++;
                    physicalCoreCount += (uint)moProcessor[WmicCpuInfoKeyNames.NumberOfCores];
                    logicalCoreCount += (uint)moProcessor[WmicCpuInfoKeyNames.NumberOfLogicalProcessors];
                    maxClockSpeed = (uint)moProcessor[WmicCpuInfoKeyNames.MaxClockSpeed];
                }
            }
            stopwatch.Stop();
            Console.WriteLine(nameof(TestGetCpuInfoViaMos1) + $" took {stopwatch.Elapsed}");
            Console.WriteLine(string.Join(",", processorModelNames) + $"# processors/phys./logical cores {processorsCount}{physicalCoreCount}{logicalCoreCount} Max clock speed: {maxClockSpeed}");
        }

        // This is actually much faster than MOS
        static void TestGetCpuInfoViaWmic()
        {
            string argList = $"{WmicCpuInfoKeyNames.Name}, {WmicCpuInfoKeyNames.NumberOfCores}, {WmicCpuInfoKeyNames.NumberOfLogicalProcessors}, {WmicCpuInfoKeyNames.MaxClockSpeed}";
            //string content = ProcessHelper.RunAndReadOutput("wmic", $"cpu get {argList} /Format:List");
            Stopwatch stopwatch = Stopwatch.StartNew();
            var processStartInfo = new ProcessStartInfo
            {
                FileName = "wmic",
                WorkingDirectory = "",
                Arguments = $"cpu get {argList} /Format:List",
                UseShellExecute = false,
                CreateNoWindow = false,
                RedirectStandardOutput = false,
                RedirectStandardError = false
            };
            using var process = new Process { StartInfo = processStartInfo };
            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                Console.WriteLine("wmic failed with exception:");
                Console.WriteLine(ex.Message);
            }
            process.WaitForExit();
            stopwatch.Stop();
            Console.WriteLine(nameof(TestGetCpuInfoViaWmic) + $" took {stopwatch.Elapsed}");
        }
    }
}
