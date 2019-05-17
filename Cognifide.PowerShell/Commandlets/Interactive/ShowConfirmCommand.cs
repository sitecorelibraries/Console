﻿using System.Management.Automation;
using Cognifide.PowerShell.Core.VersionDecoupling;
using Cognifide.PowerShell.Services;
using Sitecore.Jobs.AsyncUI;

namespace Cognifide.PowerShell.Commandlets.Interactive
{
    [Cmdlet(VerbsCommon.Show, "Confirm")]
    [OutputType(typeof (string))]
    public class ShowConfirmCommand : BaseShellCommand
    {
        [Parameter(ValueFromPipeline = true, Position = 0, Mandatory = true)]
        public string Title { get; set; }

        protected override void ProcessRecord()
        {
            LogErrors(() =>
            {
                if (!CheckSessionCanDoInteractiveAction()) return;

                var jobUiManager = TypeResolver.Resolve<IJobUiManager>();
                var response = jobUiManager.Confirm(Title);
                WriteObject(response);
            });
        }
    }
}