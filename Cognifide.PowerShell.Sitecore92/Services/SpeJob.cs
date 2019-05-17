﻿using System.Collections.Specialized;
using Cognifide.PowerShell.Services;
using Sitecore;
using Sitecore.Abstractions;
using Sitecore.Jobs;
using Sitecore.Jobs.AsyncUI;

namespace Cognifide.PowerShell.VersionSpecific.Services
{
    public class SpeJob : IJob
    {
        public Handle Handle { get; }

        internal BaseJob Job { get; set; }

        public MessageQueue MessageQueue => Job.MessageQueue as MessageQueue;

        public string Name => Job.Name;

        public bool StatusFailed
        {
            get => Job.Status.Failed;
            set => Job.Status.Failed = value;
        }

        public object StatusResult
        {
            get => Job.Status.Result;
            set => Job.Status.Result = value;
        }

        public StringCollection StatusMessages => Job.Status.Messages;

        public IJobOptions Options => (SpeJobOptions)Job.Options;

        public SpeJob(Handle handle)
        {
            Handle = handle;
            Job = JobManager.GetJob(handle);
        }

        public SpeJob(BaseJob job)
        {
            Job = job;
        }

        public void AddStatusMessage(string message)
        {
            Job.Status.Messages.Add(message);
        }

        public static implicit operator BaseJob(SpeJob job)
        {
            return job.Job;
        }
    }
}
