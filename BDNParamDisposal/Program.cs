// Copyright (c) 2021 Matthias Wolf, Mawosoft.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Engines;
using BenchmarkDotNet.Jobs;
using BenchmarkDotNet.Running;
using BenchmarkDotNet.Toolchains.InProcess.Emit;

namespace BDNParamDisposal
{
    internal static class LogManager
    {
        private const string Title = nameof(BDNParamDisposal);
        private const string EnvVarLogFile = Title + "_LogFile";

        private static readonly HashSet<string> s_stackTraceStrings = new();
        private static readonly Dictionary<string, int> s_instanceIds = new();

        public static TextWriter Out { get; private set; }

        static LogManager()
        {
            string? logfile = Environment.GetEnvironmentVariable(EnvVarLogFile);
            if (logfile == null)
            {
                string now = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                Directory.CreateDirectory(DefaultConfig.Instance.ArtifactsPath);
                logfile = Path.Combine(DefaultConfig.Instance.ArtifactsPath, $"{Title}-Generated-{now}.log");
                Environment.SetEnvironmentVariable(EnvVarLogFile, logfile);
                logfile = Path.Combine(DefaultConfig.Instance.ArtifactsPath, $"{Title}-Host-{now}.log");
                Out = new StreamWriter(logfile, false);
            }
            else
            {
                Out = new StreamWriter(logfile, true);
            }
            Out.WriteLine("________________________________________________________________________");
            Out.WriteLine(Environment.CommandLine);
            Out.WriteLine();
            Out.Flush();
        }

        public static void Log(this DisposableParamOrArgument param)
        {
            lock (s_instanceIds)
            {
                if (param.InstanceId == 0)
                {
                    string typeName = param.GetType().Name;
                    s_instanceIds.TryAdd(typeName, 0);
                    param.InstanceId = s_instanceIds[typeName] = s_instanceIds[typeName] + 1;
                }
                StackTrace stackTrace = new(2);
                StackFrame stackFrame = new(1);
                string methodName = stackFrame.GetMethod()?.Name ?? "";
                string disposeCount = methodName == "Dispose" ? $" {++param.DisposeCount}" : "";
                Out.WriteLine($"{param.GetType().Name} {param.InstanceId} {methodName}{disposeCount}");
                string stackTraceString = stackTrace.ToString();
                if (s_stackTraceStrings.Add(stackTraceString))
                {
                    Out.WriteLine(stackTraceString);
                }
                Out.Flush();
            }
        }

        public static void Log(string text)
        {
            lock (s_instanceIds)
            {
                Out.WriteLine(text);
                Out.Flush();
            }
        }
    }

    public abstract class DisposableParamOrArgument : IDisposable
    {
        public int DisposeCount { get; set; }
        public int InstanceId { get; set; }
        public override string ToString() => $"{GetType().Name} {InstanceId}";
        public DisposableParamOrArgument() => this.Log();
        ~DisposableParamOrArgument() => this.Log();

        [SuppressMessage("Usage", "CA1816:Dispose methods should call SuppressFinalize", Justification = "Logging")]
        public void Dispose() => this.Log();
        public void Method() => this.Log();
    }

    // Using shortened class name for display
    public class DsplParam : DisposableParamOrArgument { }

    public class DsplArgum : DisposableParamOrArgument { }

    public class Benchmarks1
    {
        [GlobalCleanup]
        public void Cleanup()
        {
            LogManager.Log("GlobalCleanup Begin");
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            LogManager.Log("GlobalCleanup Done");
        }

        public IEnumerable<DsplParam> Params()
        {
            yield return new DsplParam();
            yield return new DsplParam();
        }

        public IEnumerable<DsplArgum> Args()
        {
            yield return new DsplArgum();
            yield return new DsplArgum();
        }

        [ParamsSource(nameof(Params))]
        public DsplParam? Prop1 { get; set; }

        [Benchmark]
        [ArgumentsSource(nameof(Args))]
        public void Bm1Method1(DsplArgum arg1)
        {
            arg1.Method();
            Prop1?.Method();
        }
        [Benchmark]
        [ArgumentsSource(nameof(Args))]
        public string Bm1Method2(DsplArgum arg1)
        {
            arg1.Method();
            Prop1?.Method();
            return arg1.GetType().Name;
        }
        [Benchmark]
        public Type? Bm1Method3()
        {
            Prop1?.Method();
            return Prop1?.GetType();
        }
    }

    internal class Program
    {
        internal static void Main(string[] args)
        {
            Job monitor = new Job("Monitor")
                .WithStrategy(RunStrategy.Monitoring)
                .WithLaunchCount(1)
                .WithWarmupCount(2)
                .WithIterationCount(2)
                .WithUnrollFactor(1)
                .Freeze();
            ManualConfig config = ManualConfig.Create(DefaultConfig.Instance)
                .WithOptions(ConfigOptions.KeepBenchmarkFiles | ConfigOptions.DisableOptimizationsValidator)
                .AddJob(monitor.WithToolchain(InProcessEmitToolchain.Instance)
                               .WithId("MonitorInProc")
                               .AsBaseline(),
                        monitor.WithCustomBuildConfiguration("Debug")
                        );
            BenchmarkRunner.Run(typeof(Program).Assembly, config, args);
            LogManager.Log("MainCleanup Begin");
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            LogManager.Log("MainCleanup Done");
        }
    }
}
