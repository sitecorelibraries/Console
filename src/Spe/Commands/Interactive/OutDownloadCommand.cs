﻿using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using Spe.Commands.Interactive.Messages;
using Spe.Core.Extensions;
using Spe.Core.Settings.Authorization;

namespace Spe.Commands.Interactive
{
    [Cmdlet(VerbsData.Out, "Download")]
    [OutputType(typeof(string))]
    public class OutDownloadCommand : BaseShellCommand
    {

        [Parameter(Mandatory = true, ValueFromPipeline = true)]
        public object InputObject { get; set; }

        [Parameter]
        public string ContentType { get; set; }

        [Parameter(ValueFromPipelineByPropertyName = true)]
        public string Name { get; set; }

        protected override void ProcessRecord()
        {
            LogErrors(() =>
            {
                if (!CheckSessionCanDoInteractiveAction()) return;

                object content;
                InputObject = InputObject.BaseObject();

                switch (InputObject)
                {
                    case Stream inputObject:
                        {
                            using (var stream = inputObject)
                            {
                                var bytes = new byte[stream.Length];
                                stream.Seek(0, SeekOrigin.Begin);
                                stream.Read(bytes, 0, (int)stream.Length);
                                content = bytes;
                            }

                            break;
                        }
                    case FileInfo _:
                    case string _:
                    case byte[] _:
                        content = InputObject;
                        break;
                    case string[] strings:
                        content = strings.ToList().Aggregate((accumulated, next) =>
                            accumulated + "\n" + next);
                        break;
                    default:
                        WriteError(typeof(FormatException), "InputObject must be of type string, string[], byte[], Stream or FileInfo",
                            ErrorIds.InvalidItemType, ErrorCategory.InvalidType, InputObject, true);
                        WriteObject(false);
                        return;
                }

                if (!ServiceAuthorizationManager.IsUserAuthorized(WebServiceSettings.ServiceHandleDownload, Sitecore.Context.User.Name))
                {
                    WriteError(typeof(FormatException), "Handle Download Service is disabled or user is not authorized.",
                        ErrorIds.InsufficientSecurityRights, ErrorCategory.PermissionDenied, InputObject, true);
                    WriteObject(false);
                    return;
                }

                LogErrors(() =>
                {
                    WriteObject(true);
                    PutMessage(new OutDownloadMessage(content, Name, ContentType));
                });
            });
        }

    }
}