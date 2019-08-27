using System.Collections.Generic;
using System;
using IDE.Compiler;
using System.IO;
using System.Diagnostics;
using Beefy;
using IDE.util;

namespace IDE
{
	class BuildContext
	{
		public Project mHotProject;
		public Workspace.Options mWorkspaceOptions;
		public Dictionary<Project, String> mImpLibMap = new .() ~
		{
			for (let val in _.Values)
				delete val;
			delete _;
		};
		public ScriptManager mScriptManager ~ delete _;

		public bool Failed
		{
			get
			{
				if (mScriptManager != null)
					return mScriptManager.mFailed;
				return false;
			}
		}

		public enum CustomBuildCommandResult
		{
			NoCommands,
			HadCommands,
			Failed
		}

		public CustomBuildCommandResult QueueProjectCustomBuildCommands(Project project, String targetPath, Project.BuildCommandTrigger trigger, List<String> cmdList)
		{
			if (cmdList.IsEmpty)
				return .NoCommands;

			if (trigger == .Never)
				return .NoCommands;

			if ((trigger == .IfFilesChanged) && (!project.mForceCustomCommands))
			{
				int64 highestDateTime = 0;

				int64 targetDateTime = File.GetLastWriteTime(targetPath).Get().ToFileTime();

				bool forceRebuild = false;

				for (var depName in project.mDependencies)
				{
					var depProject = gApp.mWorkspace.FindProject(depName.mProjectName);
					if (depProject != null)
					{
						if (depProject.mLastDidBuild)
							forceRebuild = true;
					}
				}

				project.WithProjectItems(scope [&] (projectItem) =>
					{
						var projectSource = projectItem as ProjectSource;
						var importPath = scope String();
						projectSource.GetFullImportPath(importPath);
						Result<DateTime> fileDateTime = File.GetLastWriteTime(importPath);
						if (fileDateTime case .Ok)
						{
							let date = fileDateTime.Get().ToFileTime();
							/*if (date > targetDateTime)
								Console.WriteLine("Custom build higher time: {0}", importPath);*/
							highestDateTime = Math.Max(highestDateTime, date);
						}
					});

				if ((highestDateTime <= targetDateTime) && (!forceRebuild))
					return .NoCommands;

				project.mLastDidBuild = true;
			}

			Workspace.Options workspaceOptions = gApp.GetCurWorkspaceOptions();
			Project.Options options = gApp.GetCurProjectOptions(project);

			bool didCommands = false;

			let targetName = scope String("Project ", project.mProjectName);

			//Console.WriteLine("Executing custom command {0} {1} {2}", highestDateTime, targetDateTime, forceRebuild);
			for (let origCustomCmd in cmdList)
			{
				bool isCommand = false;
				for (let c in origCustomCmd.RawChars)
				{
					if ((c == '\"') || (c == '$'))
						break;
					if (c == '(')
						isCommand = true;
				}

				String customCmd = scope String();

				if (isCommand)
				{
					customCmd.Append(origCustomCmd);
				}
				else
				{
					customCmd.Append("%exec ");
					gApp.ResolveConfigString(workspaceOptions, project, options, origCustomCmd, "custom command", customCmd);
				}

				if (customCmd.IsWhiteSpace)
					continue;

				if (mScriptManager == null)
				{
					mScriptManager = new .();
					mScriptManager.mProjectName = new String(project.mProjectName);
					mScriptManager.mAllowCompiling = true;
					mScriptManager.mSoftFail = true;
					mScriptManager.mVerbosity = gApp.mVerbosity;
					didCommands = true;
				}

				mScriptManager.QueueCommands(customCmd, project.mProjectName, .NoLines);
				continue;
			}

			if (didCommands)
			{
				mScriptManager.QueueCommands(scope String()..AppendF("%targetComplete {}", project.mProjectName), targetName, .NoLines);

				let targetCompleteCmd = new IDEApp.TargetCompletedCmd(project);
				targetCompleteCmd.mIsReady = false;
				gApp.mExecutionQueue.Add(targetCompleteCmd);
				project.mNeedsTargetRebuild = true;
			}

			return didCommands ? .HadCommands : .Failed;
		}

		bool QueueProjectGNULink(Project project, String targetPath, Workspace.Options workspaceOptions, Project.Options options, String objectsArg)
		{
			bool isDebug = gApp.mConfigName.IndexOf("Debug", true) != -1;

#if BF_PLATFORM_WINDOWS
			String llvmDir = scope String(IDEApp.sApp.mInstallDir);
			IDEUtils.FixFilePath(llvmDir);
			llvmDir.Append("llvm/");
#else
		    String llvmDir = "";
#endif

		    //String error = scope String();

			bool isExe = project.mGeneralOptions.mTargetType != Project.TargetType.BeefLib;
			if (isExe)
			{
			    String linkLine = scope String(isDebug ? "-g " : "-g -O2 "); //-O2 -Rpass=inline 
																 //(doClangCPP ? "-lc++abi " : "") +
			    
			    linkLine.Append("-o ");
			    IDEUtils.AppendWithOptionalQuotes(linkLine, targetPath);
			    linkLine.Append(" ");

			    /*if (options.mBuildOptions.mLinkerType == Project.LinkerType.GCC)
			    {
					// ...
			    }
			    else
			    {
					linkLine.Append("--target=");
					GetTargetName(workspaceOptions, linkLine);
					linkLine.Append(" ");
			    }*/

			    if ((project.mGeneralOptions.mTargetType == Project.TargetType.BeefWindowsApplication) ||
			        (project.mGeneralOptions.mTargetType == Project.TargetType.C_WindowsApplication))
			    {
			        linkLine.Append("-mwindows ");
			    }

				linkLine.Append("-no-pie ");

			    linkLine.Append(objectsArg);

				//var destDir = scope String();
				//Path.GetDirectoryName();

				//TODO: Make an option
			    if (options.mBuildOptions.mCLibType == Project.CLibType.Static)
			    {
			        linkLine.Append("-static-libgcc -static-libstdc++ ");
			    }
			    else
			    {
#if BF_PLATFORM_WINDOWS
			        String[] mingwFiles;
			        String fromDir;
			        if (workspaceOptions.mMachineType == Workspace.MachineType.x86)
			        {
			            fromDir = scope:: String(llvmDir, "i686-w64-mingw32/bin/");
			            mingwFiles = scope:: String[] { "libgcc_s_dw2-1.dll", "libstdc++-6.dll" };
			        }
			        else
			        {
			            fromDir = scope:: String(llvmDir, "x86_64-w64-mingw32/bin/");
			            mingwFiles = scope:: String[] { "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll" };
			        }
			        for (var mingwFile in mingwFiles)
			        {
			            String fromPath = scope String(fromDir, mingwFile);
						//string toPath = projectBuildDir + "/" + mingwFile;
			            String toPath = scope String();
			            Path.GetDirectoryPath(targetPath, toPath);
			            toPath.Append("/", mingwFile);
			            if (!File.Exists(toPath))
						{
							if (File.Copy(fromPath, toPath) case .Err)
							{
								gApp.OutputLineSmart("ERROR: Failed to copy mingw file {0}", fromPath);
								return false;
							}
						}
			        }
#endif
			    }

			    List<Project> depProjectList = scope List<Project>();
			    gApp.GetDependentProjectList(project, depProjectList);
			    if (depProjectList.Count > 0)
			    {
			        for (var dep in project.mDependencies)
			        {
			            var depProject = gApp.mWorkspace.FindProject(dep.mProjectName);
			            if (depProject == null)
			            {
			                gApp.OutputLine("Failed to locate dependent library: {0}", dep.mProjectName);
			                return false;
			            }
			            else
			            {                                                        
		                    /*if (depProject.mNeedsTargetRebuild)
		                        project.mNeedsTargetRebuild = true;*/

		                    var depOptions = gApp.GetCurProjectOptions(depProject);

		                    if (depOptions.mClangObjectFiles != null)
		                    {
		                        var argBuilder = scope IDEApp.ArgBuilder(linkLine, true);

		                        for (var fileName in depOptions.mClangObjectFiles)
		                        {
		                            //AppendWithOptionalQuotes(linkLine, fileName);
		                            argBuilder.AddFileName(fileName);
		                            argBuilder.AddSep();
		                        }
		                    }


		                    /*String depLibTargetPath = scope String();
		                    ResolveConfigString(depProject, depOptions, "$(TargetPath)", error, depLibTargetPath);
		                    IDEUtils.FixFilePath(depLibTargetPath);

		                    String depDir = scope String();
		                    Path.GetDirectoryName(depLibTargetPath, depDir);
		                    String depFileName = scope String();
		                    Path.GetFileNameWithoutExtension(depLibTargetPath, depFileName);

		                    AppendWithOptionalQuotes(linkLine, depLibTargetPath);
		                    linkLine.Append(" ");*/
			            }
			        }
			    }

#if BF_PLATFORM_WINDOWS
			    String gccExePath = "c:/mingw/bin/g++.exe";
			    String clangExePath = scope String(llvmDir, "bin/clang++.exe");
#else
		        String gccExePath = "/usr/bin/c++";
		        String clangExePath = scope String("/usr/bin/c++");
#endif

			    if (project.mNeedsTargetRebuild)
			    {
			        if (File.Delete(targetPath) case .Err)
					{
					    gApp.OutputLine("Failed to delete {0}", targetPath);
					    return false;
					}

					if (workspaceOptions.mToolsetType == .GNU)
					{
			            if (workspaceOptions.mMachineType == Workspace.MachineType.x86)
			            {
			            }
			            else
			            {
							IDEUtils.AppendWithOptionalQuotes(linkLine, scope String("-L", llvmDir, "/x86_64-w64-mingw32/lib"));
							linkLine.Append(" ");
							IDEUtils.AppendWithOptionalQuotes(linkLine, scope String("-L", llvmDir, "/lib/gcc/x86_64-w64-mingw32/5.2.0"));
							linkLine.Append(" ");
			            }
					}
					else // Microsoft
					{
						if (workspaceOptions.mMachineType == Workspace.MachineType.x86)
						{
							//linkLine.Append("-L\"C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\10.0.10586.0\\ucrt\\x86\" ");
							for (var libPath in gApp.mSettings.mVSSettings.mLib32Paths)
							{
								linkLine.AppendF("-L\"{0}\" ", libPath);
							}
						}
						else
						{
							/*linkLine.Append("-L\"C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\lib\\amd64\" ");
							linkLine.Append("-L\"C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\atlmfc\\lib\\amd64\" ");
							linkLine.Append("-L\"C:\\Program Files (x86)\\Windows Kits\\10\\lib\\10.0.14393.0\\ucrt\\x64\" ");
							linkLine.Append("-L\"C:\\Program Files (x86)\\Windows Kits\\10\\lib\\10.0.14393.0\\um\\x64\" ");*/
							for (var libPath in gApp.mSettings.mVSSettings.mLib64Paths)
							{
								linkLine.AppendF("-L\"{0}\" ", libPath);
							}
						}
					}

					if (options.mBuildOptions.mOtherLinkFlags.Length != 0)
					{
						var linkFlags = scope String();
						gApp.ResolveConfigString(workspaceOptions, project, options, options.mBuildOptions.mOtherLinkFlags, "link flags", linkFlags);
						linkLine.Append(linkFlags, " ");
					}

			        String compilerExePath = (workspaceOptions.mToolsetType == .GNU) ? gccExePath : clangExePath;
					String workingDir = scope String();
					if (!llvmDir.IsEmpty)
					{
						workingDir.Append(llvmDir, "bin");
					}
					else
					{
						workingDir.Append(gApp.mInstallDir);
					}

			        var runCmd = gApp.QueueRun(compilerExePath, linkLine, workingDir, .UTF8);
			        runCmd.mOnlyIfNotFailed = true;
			        var tagetCompletedCmd = new IDEApp.TargetCompletedCmd(project);
			        tagetCompletedCmd.mOnlyIfNotFailed = true;
			        gApp.mExecutionQueue.Add(tagetCompletedCmd);

					String logStr = scope String();
					logStr.AppendF("IDE Process {0}\r\n", Platform.BfpProcess_GetCurrentId());
					logStr.Append(linkLine);
					String targetLogPath = scope String(targetPath, ".build.txt");
					Utils.WriteTextFile(targetLogPath, logStr);

					project.mLastDidBuild = true;
			    }
			}

			return true;
		}

		public static void GetPdbPath(String targetPath, Workspace.Options workspaceOptions, Project.Options options, String outPdbPath)
		{
			int lastDotPos = targetPath.LastIndexOf('.');
			outPdbPath.Append(targetPath, 0, lastDotPos);
			if (workspaceOptions.mToolsetType == .LLVM)
				outPdbPath.Append("_lld");
			outPdbPath.Append(".pdb");
		}

		public static void GetRtLibNames(Workspace.Options workspaceOptions, Project.Options options, bool dynName, String outRt, String outDbg)
		{
			if ((!dynName) || (options.mBuildOptions.mBeefLibType != .Static))
			{
				outRt.Append("Beef", IDEApp.sRTVersionStr, "RT");
				outRt.Append((workspaceOptions.mMachineType == .x86) ? "32" : "64");
				switch (options.mBuildOptions.mBeefLibType)
				{
				case .Dynamic:
				case .DynamicDebug: outRt.Append("_d");
				case .Static:
					switch (options.mBuildOptions.mCLibType)
					{
					case .None:
					case .Dynamic, .SystemMSVCRT: outRt.Append("_s");
					case .DynamicDebug: outRt.Append("_sd");
					case .Static: outRt.Append("_ss");
					case .StaticDebug: outRt.Append("_ssd");
					}
				}
				outRt.Append(dynName ? ".dll" : ".lib");
			}

			if ((workspaceOptions.mEnableObjectDebugFlags) || (workspaceOptions.mAllocType == .Debug))
			{
				outDbg.Append("Beef", IDEApp.sRTVersionStr, "Dbg");
				outDbg.Append((workspaceOptions.mMachineType == .x86) ? "32" : "64");
				if (options.mBuildOptions.mBeefLibType == .DynamicDebug)
					outDbg.Append("_d");
				outDbg.Append(dynName ? ".dll" : ".lib");
			}

			/*if ((workspaceOptions.mEnableObjectDebugFlags) &&
				((!dynName) || (options.mBuildOptions.mBeefLibType != .Static)))
			{
				outDbg.Append("Beef", IDEApp.sRTVersionStr, "Dbg");
				outDbg.Append((workspaceOptions.mMachineType == .x86) ? "32" : "64");
				switch (options.mBuildOptions.mBeefLibType)
				{
				case .Dynamic:
				case .DynamicDebug: outDbg.Append("_d");
				case .Static:
					switch (options.mBuildOptions.mCLibType)
					{
					case .None:
					case .Dynamic, .SystemMSVCRT: outDbg.Append("_s");
					case .DynamicDebug: outDbg.Append("_sd");
					case .Static: outDbg.Append("_ss");
					case .StaticDebug: outDbg.Append("_ssd");
					}
				}
				outDbg.Append(dynName ? ".dll" : ".lib");
			}*/
		}

		bool QueueProjectMSLink(Project project, String targetPath, String configName, Workspace.Options workspaceOptions, Project.Options options, String objectsArg)
		{
			String llvmDir = scope String(IDEApp.sApp.mInstallDir);
			IDEUtils.FixFilePath(llvmDir);
			llvmDir.Append("llvm/");

			TestManager.ProjectInfo testProjectInfo = null;
			if (gApp.mTestManager != null)
				testProjectInfo = gApp.mTestManager.GetProjectInfo(project);

			bool isExe = (project.mGeneralOptions.mTargetType != Project.TargetType.BeefLib) || (testProjectInfo != null);
			if (isExe)
			{
				String linkLine = scope String();
			    
			    linkLine.Append("-out:");
			    IDEUtils.AppendWithOptionalQuotes(linkLine, targetPath);
			    linkLine.Append(" ");

				if (testProjectInfo != null)
					linkLine.Append("-subsystem:console ");
			    else if (project.mGeneralOptions.mTargetType == .BeefWindowsApplication)
					linkLine.Append("-subsystem:windows ");
			    else if (project.mGeneralOptions.mTargetType == .C_WindowsApplication)
			    	linkLine.Append("-subsystem:console ");
				else if (project.mGeneralOptions.mTargetType == .BeefDynLib)
				{
					linkLine.Append("-dll ");

					if (targetPath.EndsWith(".dll", .InvariantCultureIgnoreCase))
					{
						linkLine.Append("-implib:\"");
						linkLine.Append(targetPath, 0, targetPath.Length - 4);
						linkLine.Append(".lib\" ");
					}
				}

			    linkLine.Append(objectsArg);

				//var destDir = scope String();
				//Path.GetDirectoryName();

				//TODO: Allow selecting lib file.  Check date when copying instead of just ALWAYS copying...
				LibBlock:
			    {
			        List<String> stdLibFileNames = scope .(2);
			        String fromDir;
			        
		            fromDir = scope String(gApp.mInstallDir);

					bool AddLib(String dllName)
					{
						stdLibFileNames.Add(dllName);

						String fromPath = scope String(fromDir, dllName);
						String toPath = scope String();
						Path.GetDirectoryPath(targetPath, toPath);
						toPath.Append("/", dllName);
						if (File.CopyIfNewer(fromPath, toPath) case .Err)
						{
							gApp.OutputLine("Failed to copy lib file {0}", fromPath);
							return false;
						}
						return true;
					}

					String rtName = scope String();
					String dbgName = scope String();
					GetRtLibNames(workspaceOptions, options, true, rtName, dbgName);
					if (!rtName.IsEmpty)
						if (!AddLib(rtName))
							return false;
					if (!dbgName.IsEmpty)
						if (!AddLib(dbgName))
							return false;
					switch (workspaceOptions.mAllocType)
					{
					case .JEMalloc:
						if (!AddLib("jemalloc.dll"))
							return false;
					default:
					}
			    }

			    List<Project> depProjectList = scope List<Project>();
			    gApp.GetDependentProjectList(project, depProjectList);
			    if (depProjectList.Count > 0)
			    {
			        for (var dep in project.mDependencies)
			        {
			            var depProject = gApp.mWorkspace.FindProject(dep.mProjectName);
			            if (depProject == null)
			            {
			                gApp.OutputLine("Failed to locate dependent library: {0}", dep.mProjectName);
			                return false;
			            }
			            else
			            {
			                /*if (depProject.mNeedsTargetRebuild)
			                    project.mNeedsTargetRebuild = true;*/

			                var depOptions = gApp.GetCurProjectOptions(depProject);
							if (depOptions != null)
							{
								if (depOptions.mClangObjectFiles != null)
		                        {
									var argBuilder = scope IDEApp.ArgBuilder(linkLine, true);

									for (var fileName in depOptions.mClangObjectFiles)
									{
										//AppendWithOptionalQuotes(linkLine, fileName);
										argBuilder.AddFileName(fileName);
										argBuilder.AddSep();
									}
								}    
							}

							if (depProject.mGeneralOptions.mTargetType == .BeefDynLib)
							{
								if (mImpLibMap.TryGetValue(depProject, var libPath))
								{
									IDEUtils.AppendWithOptionalQuotes(linkLine, libPath);
									linkLine.Append(" ");
								}
							}


			                /*String depLibTargetPath = scope String();
			                ResolveConfigString(depProject, depOptions, "$(TargetPath)", error, depLibTargetPath);
							IDEUtils.FixFilePath(depLibTargetPath);

			                String depDir = scope String();
			                Path.GetDirectoryName(depLibTargetPath, depDir);
			                String depFileName = scope String();
			                Path.GetFileNameWithoutExtension(depLibTargetPath, depFileName);

							AppendWithOptionalQuotes(linkLine, depLibTargetPath);
							linkLine.Append(" ");*/
			            }
			        }
			    }

			    if (project.mNeedsTargetRebuild)
			    {
			        /*if (File.Delete(targetPath).Failed(true))
					{
					    OutputLine("Failed to delete {0}", targetPath);
					    return false;
					}*/

					switch (options.mBuildOptions.mCLibType)
					{
					case .None:
						linkLine.Append("-nodefaultlib ");
					case .Dynamic:
						//linkLine.Append((workspaceOptions.mMachineType == .x86) ? "-defaultlib:msvcprt " : "-defaultlib:msvcrt ");
						linkLine.Append("-defaultlib:msvcrt ");
					case .Static:
						//linkLine.Append((workspaceOptions.mMachineType == .x86) ? "-defaultlib:libcpmt " : "-defaultlib:libcmt ");
						linkLine.Append("-defaultlib:libcmt ");
					case .DynamicDebug:
						//linkLine.Append((workspaceOptions.mMachineType == .x86) ? "-defaultlib:msvcprtd " : "-defaultlib:msvcrtd ");
						linkLine.Append("-defaultlib:msvcrtd ");
					case .StaticDebug:
						//linkLine.Append((workspaceOptions.mMachineType == .x86) ? "-defaultlib:libcpmtd " : "-defaultlib:libcmtd ");
						linkLine.Append("-defaultlib:libcmtd ");
					case .SystemMSVCRT:
						linkLine.Append("-nodefaultlib ");

						String minRTModName = scope String();
						if ((project.mGeneralOptions.mTargetType == .BeefWindowsApplication) ||
							(project.mGeneralOptions.mTargetType == .C_WindowsApplication))
							minRTModName.Append("g");
						if (options.mBuildOptions.mBeefLibType == .DynamicDebug)
							minRTModName.Append("d");
						if (!minRTModName.IsEmpty)
							minRTModName.Insert(0, "_");

						if (workspaceOptions.mMachineType == .x86)
							linkLine.Append(gApp.mInstallDir, @"lib\x86\msvcrt.lib Beef", IDEApp.sRTVersionStr,"MinRT32", minRTModName, ".lib ");
						else
							linkLine.Append(gApp.mInstallDir, @"lib\x64\msvcrt.lib Beef", IDEApp.sRTVersionStr,"MinRT64", minRTModName, ".lib ");
						linkLine.Append("ntdll.lib user32.lib kernel32.lib gdi32.lib winmm.lib shell32.lib ole32.lib rpcrt4.lib chkstk.obj -ignore:4049 -ignore:4217 ");
					}
					linkLine.Append("-nologo ");
					//linkLine.Append("-fixed ");

					// Incremental just seems to be slower for Beef.  Test on larger projects to verify
					linkLine.Append("-incremental:no ");

					if (options.mBuildOptions.mStackSize > 0)
						linkLine.AppendF("-stack:{} ", options.mBuildOptions.mStackSize);

					linkLine.Append("-pdb:");
					let pdbName = scope String();
					GetPdbPath(targetPath, workspaceOptions, options, pdbName);
					IDEUtils.AppendWithOptionalQuotes(linkLine, pdbName);
					linkLine.Append(" ");

					//TODO: Only add -debug if we have some debug info?
					//if (isDebug)
					if (workspaceOptions.mEmitDebugInfo != .No)
						linkLine.Append("-debug ");

					if (workspaceOptions.mBfOptimizationLevel.IsOptimized())
						//linkLine.Append("-opt:ref -verbose ");
						linkLine.Append("-opt:ref ");
					else
						linkLine.Append("-opt:noref ");

					if (workspaceOptions.mMachineType == .x86)
					{
						//linkLine.Append("-libpath:\"C:\\Program Files (x86)\\Windows Kits\\10\\Lib\\10.0.10586.0\\ucrt\\x86\" ");
						for (var libPath in gApp.mSettings.mVSSettings.mLib32Paths)
						{
							linkLine.AppendF("-libpath:\"{0}\" ", libPath);
						}
						linkLine.Append("-libpath:\"", gApp.mInstallDir, "lib\\x86\" ");
					}
					else
					{
						/*linkLine.Append("-libpath:\"C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\lib\\amd64\" ");
						linkLine.Append("-libpath:\"C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\atlmfc\\lib\\amd64\" ");
						linkLine.Append("-libpath:\"C:\\Program Files (x86)\\Windows Kits\\10\\lib\\10.0.14393.0\\ucrt\\x64\" ");
						linkLine.Append("-libpath:\"C:\\Program Files (x86)\\Windows Kits\\10\\lib\\10.0.14393.0\\um\\x64\" ");*/
						for (var libPath in gApp.mSettings.mVSSettings.mLib64Paths)
						{
							linkLine.AppendF("-libpath:\"{0}\" ", libPath);
						}
						linkLine.Append("-libpath:\"", gApp.mInstallDir, "lib\\x64\" ");
					}

					String targetDir = scope String();
					Path.GetDirectoryPath(targetPath, targetDir);
					linkLine.Append("-libpath:");
					IDEUtils.AppendWithOptionalQuotes(linkLine, targetDir);
					linkLine.Append(" ");

					if (options.mBuildOptions.mOtherLinkFlags.Length != 0)
					{
						var linkFlags = scope String();
						gApp.ResolveConfigString(workspaceOptions, project, options, options.mBuildOptions.mOtherLinkFlags, "link flags", linkFlags);
						linkLine.Append(linkFlags, " ");
					}

					let winOptions = project.mWindowsOptions;
					/*if (!String.IsNullOrWhiteSpace(project.mWindowsOptions.mManifestFile))
					{
						String manifestPath = scope String();
						String error = scope String();
						ResolveConfigString(project, options, winOptions.mManifestFile, error, manifestPath);
						if (!manifestPath.IsWhiteSpace)
						{
							linkLine.Append("/MANIFEST:EMBED /MANIFESTINPUT:");
							IDEUtils.AppendWithOptionalQuotes(linkLine, manifestPath);
							linkLine.Append(" ");
						}
					}*/

					// Put back
					if ((!String.IsNullOrWhiteSpace(project.mWindowsOptions.mIconFile)) ||
						(!String.IsNullOrWhiteSpace(project.mWindowsOptions.mManifestFile)) ||
		                (winOptions.HasVersionInfo()))
					{						
						String projectBuildDir = scope String();
						gApp.GetProjectBuildDir(project, projectBuildDir);

						String resOutPath = scope String();
						resOutPath.Append(projectBuildDir, "\\Resource.res");

						String iconPath = scope String();
						gApp.ResolveConfigString(workspaceOptions, project, options, winOptions.mIconFile, "icon file", iconPath);
						
						// Generate resource
						Result<void> CreateResourceFile()
						{
		                    ResourceGen resGen = scope ResourceGen();
							if (resGen.Start(resOutPath) case .Err)
							{
								gApp.OutputErrorLine("Failed to create resource file '{0}'", resOutPath);
								return .Err;
							}
							if (!iconPath.IsWhiteSpace)
							{
								Path.GetAbsolutePath(scope String(iconPath), project.mProjectDir, iconPath..Clear());
								if (resGen.AddIcon(iconPath) case .Err)
								{
									gApp.OutputErrorLine("Failed to add icon");
									return .Err;
								}
							}

							let targetFileName = scope String();
							Path.GetFileName(targetPath, targetFileName);

							if (resGen.AddVersion(winOptions.mDescription, winOptions.mComments, winOptions.mCompany, winOptions.mProduct,
		                        winOptions.mCopyright, winOptions.mFileVersion, winOptions.mProductVersion, targetFileName) case .Err)
							{
								gApp.OutputErrorLine("Failed to add version");
								return .Err;
							}

							String manifestPath = scope String();
							gApp.ResolveConfigString(workspaceOptions, project, options, winOptions.mManifestFile, "manifest file", manifestPath);
							if (!manifestPath.IsWhiteSpace)
							{
								Path.GetAbsolutePath(scope String(manifestPath), project.mProjectDir, manifestPath..Clear());
								if (resGen.AddManifest(manifestPath) case .Err)
								{
									gApp.OutputErrorLine("Failed to add manifest file");
									return .Err;
								}
							}

							Try!(resGen.Finish());
							return .Ok;
						}

						if (CreateResourceFile() case .Err)
						{
							gApp.OutputErrorLine("Failed to generate resource file: {0}", resOutPath);
							return false;
						}

						IDEUtils.AppendWithOptionalQuotes(linkLine, resOutPath);
					}
					

			        //String linkerPath = "C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\bin\\amd64\\link.exe";

					let binPath = (workspaceOptions.mMachineType == .x86) ? gApp.mSettings.mVSSettings.mBin32Path : gApp.mSettings.mVSSettings.mBin64Path;
					if (binPath.IsWhiteSpace)
					{
						gApp.OutputErrorLine("Visual Studio tool path not configured. Check Visual Studio configuration in File\\Preferences\\Settings.");
						return false;
					}

					String linkerPath = scope String();
					linkerPath.Append(binPath);
					linkerPath.Append("/link.exe");
					if (workspaceOptions.mToolsetType == .LLVM)
					{
						linkerPath.Clear();
						linkerPath.Append(gApp.mInstallDir);
						linkerPath.Append(@"llvm\bin\lld-link.exe");
						//linkerPath = @"C:\Program Files\LLVM\bin\lld-link.exe";

						var ltoType = workspaceOptions.mLTOType;
						if (options.mBeefOptions.mLTOType != null)
							ltoType = options.mBeefOptions.mLTOType.Value;

						if (ltoType == .Thin)
						{
							linkLine.Append(" /lldltocache:");

							String ltoPath = scope String();
							Path.GetDirectoryPath(targetPath, ltoPath);
							ltoPath.Append("/ltocache");
							IDEUtils.AppendWithOptionalQuotes(linkLine, ltoPath);
						}
					}
					//String linkerPath = "C:\\Beef\\IDE\\dist\\BeefLink.exe";

					//QueueRun(compilerExePath, linkLine, @"c:\mingw\bin", (options.mGeneralOptions.mLinkerType == Project.LinkerType.Clang) && (linkLine.Length > 1024));
					//QueueRun(compilerExePath, linkLine, @"c:\mingw\bin", (linkLine.Length > 1024));

			        var runCmd = gApp.QueueRun(linkerPath, linkLine, gApp.mInstallDir, .UTF16WithBom);
			        runCmd.mOnlyIfNotFailed = true;
			        var tagetCompletedCmd = new IDEApp.TargetCompletedCmd(project);
			        tagetCompletedCmd.mOnlyIfNotFailed = true;
			        gApp.mExecutionQueue.Add(tagetCompletedCmd);

					String logStr = scope String();
					logStr.AppendF("IDE Process {0}\r\n", Platform.BfpProcess_GetCurrentId());
					logStr.Append(linkLine);
					String targetLogPath = scope String(targetPath, ".build.txt");
					Utils.WriteTextFile(targetLogPath, logStr);

					project.mLastDidBuild = true;
			    }
			}

			return true;
		}

		public bool QueueProjectCompile(Project project, Project hotProject, IDEApp.BuildCompletedCmd completedCompileCmd, List<String> hotFileNames, bool runAfter)
		{
			project.mLastDidBuild = false;

			TestManager.ProjectInfo testProjectInfo = null;
			if (gApp.mTestManager != null)
				testProjectInfo = gApp.mTestManager.GetProjectInfo(project);

			var configSelection = gApp.GetCurConfigSelection(project);
		    Project.Options options = gApp.GetCurProjectOptions(project);
		    if (options == null)
		        return true;

		    Workspace.Options workspaceOptions = gApp.GetCurWorkspaceOptions();
		    BfCompiler bfCompiler = gApp.mBfBuildCompiler;            
		    var bfProject = gApp.mBfBuildSystem.mProjectMap[project];
		    bool bfHadOutputChanges;
		    List<String> bfFileNames = scope List<String>();
			bfCompiler.GetOutputFileNames(bfProject, true, out bfHadOutputChanges, bfFileNames);
			defer ClearAndDeleteItems(bfFileNames);//DeleteAndClearItems!(bfFileNames);
		    if (bfHadOutputChanges)
		        project.mNeedsTargetRebuild = true;

		    List<ProjectSource> allFileNames = scope List<ProjectSource>();
		    List<String> clangAllObjNames = scope List<String>();
		    //List<String> clangObjNames = scope List<String>();            

		    gApp.GetClangFiles(project.mRootFolder, allFileNames);

		    String workspaceBuildDir = scope String();
		    gApp.GetWorkspaceBuildDir(workspaceBuildDir);
		    String projectBuildDir = scope String();
		    gApp.GetProjectBuildDir(project, projectBuildDir);
			if (!projectBuildDir.IsEmpty)
		    	Directory.CreateDirectory(projectBuildDir).IgnoreError();

		    //List<String> buildFileNames = new List<String>();

			String targetPath = scope String();

		    String outputDir = scope String();
			String absOutputDir = scope String();
			
			if (testProjectInfo != null)
			{
				absOutputDir.Append(projectBuildDir);
				outputDir = absOutputDir;
				targetPath.Append(outputDir, "/", project.mProjectName);
#if BF_PLATFORM_WINDOWS
				targetPath.Append(".exe");
#endif

				Debug.Assert(testProjectInfo.mTestExePath == null);
				testProjectInfo.mTestExePath = new String(targetPath);
			}
			else
		    {
				gApp.ResolveConfigString(workspaceOptions, project, options, options.mBuildOptions.mTargetDirectory, "target directory", outputDir);
				Path.GetAbsolutePath(project.mProjectDir, outputDir, absOutputDir);
				outputDir = absOutputDir;
				gApp.ResolveConfigString(workspaceOptions, project, options, "$(TargetPath)", "target path", targetPath);
			}
			IDEUtils.FixFilePath(targetPath);
		    if (!File.Exists(targetPath))
			{
		        project.mNeedsTargetRebuild = true;

				String targetDir = scope String();
				Path.GetDirectoryPath(targetPath, targetDir);
				if (!targetDir.IsEmpty)
					Directory.CreateDirectory(targetDir).IgnoreError();
			}

			if (project.mGeneralOptions.mTargetType == .BeefDynLib)
			{
				if (targetPath.EndsWith(".dll", .InvariantCultureIgnoreCase))
				{
					String libPath = new .();
					libPath.Append(targetPath, 0, targetPath.Length - 4);
					libPath.Append(".lib");
					mImpLibMap.Add(project, libPath);
				}
			}

			switch (QueueProjectCustomBuildCommands(project, targetPath, runAfter ? options.mBuildOptions.mBuildCommandsOnRun : options.mBuildOptions.mBuildCommandsOnCompile, options.mBuildOptions.mPostBuildCmds))
			{
			case .NoCommands:
			case .HadCommands:
			case .Failed:
				completedCompileCmd.mFailed = true;
			}
				
			if (project.mGeneralOptions.mTargetType == .CustomBuild)
			{
				return true; 
			}

#if IDE_C_SUPPORT
		    bool buildAll = false;
		    String buildStringFilePath = scope String();
		    mDepClang.GetBuildStringFileName(projectBuildDir, project, buildStringFilePath);
		    String newBuildString = scope String();
		    GetClangBuildString(project, options, workspaceOptions, true, newBuildString);
			String clangBuildString = scope String();
			GetClangBuildString(project, options, workspaceOptions, false, clangBuildString);
		    newBuildString.Append("|", clangBuildString);

		    if (mDepClang.mDoDependencyCheck)
		    {   
		     	String prependStr = scope String();
				options.mCOptions.mCompilerType.ToString(prependStr);
				prependStr.Append("|");
		        newBuildString.Insert(0, prependStr);
		        String oldBuildString;
		        mDepClang.mProjectBuildString.TryGetValue(project, out oldBuildString);

				if (oldBuildString == null)
				{
					oldBuildString = new String();
		            File.ReadAllText(buildStringFilePath, oldBuildString).IgnoreError();
					mDepClang.mProjectBuildString[project] = oldBuildString;
				}

		        if (newBuildString != oldBuildString)
		        {
		            buildAll = true;
		            
		            if (case .Err = File.WriteAllText(buildStringFilePath, newBuildString))
						OutputLine("Failed to write {0}", buildStringFilePath);
					
					delete oldBuildString;
		            mDepClang.mProjectBuildString[project] = new String(newBuildString);
		        }
		    }            			

		    using (mDepClang.mMonitor.Enter())
		    {
				if (options.mClangObjectFiles == null)
					options.mClangObjectFiles = new List<String>();
				else
					ClearAndDeleteItems(options.mClangObjectFiles);

		        for (var projectSource in allFileNames)
		        {
		            var fileEntry = mDepClang.GetProjectEntry(projectSource);
		            Debug.Assert((fileEntry != null) || (!mDepClang.mCompileWaitsForQueueEmpty));

		            String filePath = scope String();
		            projectSource.GetFullImportPath(filePath);
		            String baseName = scope String();
		            Path.GetFileNameWithoutExtension(filePath, baseName);
		            String objName = stack String();
		            objName.Append(projectBuildDir, "/", baseName, (options.mCOptions.mGenerateLLVMAsm ? ".ll" : ".obj"));

					if (filePath.Contains("test2.cpp"))
					{
						NOP!();
					}	

		            bool needsRebuild = true;
		            if ((!buildAll) && (fileEntry != null))
		            {
		                mDepClang.SetEntryObjFileName(fileEntry, objName);
		                mDepClang.SetEntryBuildStringFileName(fileEntry, buildStringFilePath);                        
		                needsRebuild = mDepClang.DoesEntryNeedRebuild(fileEntry);
		            }
		            if (needsRebuild)
		            {
		                if (hotProject != null)
		                {
		                    OutputLine("Hot swap detected disallowed C/C++ change: {0}", filePath);                            
		                    return false;
		                }

		                project.mNeedsTargetRebuild = true;                        
		                var runCmd = CompileSource(project, workspaceOptions, options, filePath);
		                runCmd.mParallelGroup = 1;
		            }

					options.mClangObjectFiles.Add(new String(objName));

					if (hotProject != null)
						continue;

		            clangAllObjNames.Add(objName);

		            IdSpan sourceCharIdData;
		            String sourceCode = scope String();
		            FindProjectSourceContent(projectSource, out sourceCharIdData, true, sourceCode);
		            mWorkspace.ProjectSourceCompiled(projectSource, sourceCode, sourceCharIdData);
					sourceCharIdData.Dispose();

					String* fileEntryPtr;
		            if (completedCompileCmd.mClangCompiledFiles.Add(filePath, out fileEntryPtr))
						*fileEntryPtr = new String(filePath);
		        }
		    }
#endif

		    String llvmDir = scope String(IDEApp.sApp.mInstallDir);
		    IDEUtils.FixFilePath(llvmDir);
		    llvmDir.Append("llvm/");
		    
		    if (hotProject != null)
		    {
		        if ((hotProject == project) || (hotProject.HasDependency(project.mProjectName)))
		        {
		            for (var fileName in bfFileNames)
		                hotFileNames.Add(new String(fileName));
		        }
		    
		        return true;
		    }

		    String objectsArg = scope String();
			var argBuilder = scope IDEApp.ArgBuilder(objectsArg, workspaceOptions.mToolsetType != .GNU);
		    for (var bfFileName in bfFileNames)
		    {
				argBuilder.AddFileName(bfFileName);
				argBuilder.AddSep();
		    }

		    for (var objName in clangAllObjNames)
		    {                
		        IDEUtils.AppendWithOptionalQuotes(objectsArg, objName);
		        objectsArg.Append(" ");
		    }

			if (workspaceOptions.mToolsetType == .GNU)
			{
				if (!QueueProjectGNULink(project, targetPath, workspaceOptions, options, objectsArg))
					return false;
			}
			else // MS
			{
				if (!QueueProjectMSLink(project, targetPath, configSelection.mConfig, workspaceOptions, options, objectsArg))
					return false;
			}

		    return true;
		}
	}
}