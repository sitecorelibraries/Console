﻿using System;
using System.Linq;
using System.Management.Automation;
using Cognifide.PowerShell.PowerShellIntegrations.Modules;
using Sitecore.Data.Items;

namespace Cognifide.PowerShell.PowerShellIntegrations.Commandlets.Modules
{
    [Cmdlet(VerbsCommon.Get, "SpeModuleFeatureRoot")]
    [OutputType(new[] { typeof(Item) }, ParameterSetName = new[] { "By Feature Name", "Module from Pipeline" })]
    public class GetSpeModuleFeatureRoot : BaseCommand, IDynamicParameters
    {
        [Parameter(ValueFromPipeline = true, ValueFromPipelineByPropertyName = true, ParameterSetName = "Module from Pipeline")]
        public Module Module { get; set; }

        protected override void ProcessRecord()
        {
            string feature;
            bool featureDefined = TryGetParameter("Feature", out feature);
            if (Module != null)
            {
                WriteItem(Module.GetFeatureRoot(feature));
                return;
            }
            if (featureDefined)
            {
                if (!String.IsNullOrEmpty(feature))
                {
                    ModuleManager.GetFeatureRoots(feature).ForEach(WriteItem);
                }
            }
        }

        public GetSpeModuleFeatureRoot()
        {
            AddDynamicParameter<string>("Feature", new Attribute[]
            {
                new ParameterAttribute
                {
                    ParameterSetName = ParameterAttribute.AllParameterSets,
                    Mandatory = true,
                    Position = 0
                },
                new ValidateSetAttribute(IntegrationPoints.Libraries.Keys.ToArray())
            });
        }
    }
}