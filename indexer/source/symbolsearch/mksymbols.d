module symbolsearch.mksymbols;

import symbolsearch.types;

import std.algorithm;
import std.digest;
import std.file;
import std.stdio;
import std.path;
import std.process;

import vibe.vibe;

void fetchDubProjects()
{
	if (existsFile("dump.json"))
	{
		auto info = getFileInfo("dump.json");
		if (Clock.currTime < info.timeModified + 20.minutes)
			return;
	}

	logInfo("Fetching packages dump");

	auto proc = spawnProcess(["curl", "-s", "--compressed",
			"https://code.dlang.org/api/packages/dump", "-o", "dump.json"]);

	while (!proc.tryWait.terminated)
		sleep(1.seconds);
}

long symbolsAdded, versionsAdded, versionsRemoved, projectErrors;

void indexAllProjects()
{
	symbolsAdded = 0;
	versionsAdded = 0;
	versionsRemoved = 0;
	projectErrors = 0;

	fetchDubProjects();
	Task[16] tasks; // tasks running at once
	foreach (obj; parseJsonString(readFileUTF8("dump.json").strip, "dump.json"))
	{
		int task = -1;
		while (task == -1)
		{
			foreach (i, t; tasks)
			{
				if (!t || !t.running)
				{
					task = cast(int) i;
					break;
				}
			}
			sleep(10.msecs);
		}
		auto project = obj.deserializeJson!(ProjectDescription.DubProject);
		tasks[task] = runTask((&indexProject).toDelegate, project);
	}
	foreach (t; tasks)
		if (t && t.running)
			t.join();

	logInfo("Added %s symbols", symbolsAdded);
	logInfo("Added %s tags, removed %s tags", versionsAdded, versionsRemoved);
	logInfo("%s projects errored", projectErrors);
}

void indexProject(ProjectDescription.DubProject dub)
{
	logDiagnostic("Indexing %s", dub.name);

	auto existing = ProjectDescription.tryFindOne(["dub._id" : dub._id]);
	ProjectDescription project;
	ProjectDescription.DBVersion[] addedVersions;
	if (existing.isNull)
	{
		project.bsonID = BsonObjectID.generate;
		project.dub = dub;
	}
	else
	{
		project = existing.get;
		addedVersions = project.versions;
		project.dub = dub;
	}
	project.save();
	project.versionsFromDub();

	static assert(isWeaklyIsolated!(immutable(ProjectDescription.DBVersion[]))
			&& isWeaklyIsolated!BsonObjectID);
	auto fut = async(&doSymbolIndex, project.bsonID, project.dub.name,
			project.dub.repository.gitURL, cast(immutable) addedVersions,
			cast(immutable) project.versions);

	while (!fut.ready)
		sleep(10.msecs);

	auto res = fut.getResult;

	if (res)
	{
		logInfo("Indexed %s new symbols for %s", res.symbols.length, project.dub.name);

		symbolsAdded += res.symbols.length;
		versionsAdded += res.addedVersions.length;
		versionsRemoved += res.versionsToRemove.length;

		Symbol.insertMany(res.symbols);

		if (res.versionsToRemove.length || res.addedVersions.length)
		{
			project = ProjectDescription.findById(project.bsonID);
			foreach (id; res.versionsToRemove)
				project.versions = project.versions.remove!(a => a.commit == id);
			project.versions ~= res.addedVersions;
			project.save();
		}
	}
	else
	{
		logInfo("Errored indexing %s", project.dub.name);

		projectErrors++;
		project = ProjectDescription.findById(project.bsonID);
		project.versions.length = 0;
		project.save();
	}
}

File nullIn() @property
{
	string nul;
	version (Posix)
		nul = "/dev/null";
	else version (Windows)
		nul = "NUL";
	else
		static assert(false);
	return File(nul, "rb");
}

struct SymbolIndexResult
{
	ubyte[][] versionsToRemove;
	ProjectDescription.DBVersion[] addedVersions;
	Symbol[] symbols;
}

SymbolIndexResult* doSymbolIndex(BsonObjectID projectID, string dubName, string repository,
		immutable(ProjectDescription.DBVersion[]) addedVersions,
		immutable(ProjectDescription.DBVersion[]) versions)
{
	ubyte[][] toRemove;
	ProjectDescription.DBVersion[] processed;
	Symbol[] symbols;
	auto path = buildPath("clones", projectID.toString ~ "-" ~ dubName);
	if (!exists(path))
		mkdirRecurse(path);
	environment["GIT_TERMINAL_PROMPT"] = "0";

	int git(string[] args)
	{
		auto ret = spawnProcess("git" ~ args, nullIn, stderr, stderr, null, Config.none, path);
		while (!ret.tryWait.terminated)
			sleep(1.msecs);
		return ret.wait;
	}

	if (!existsFile(buildPath(path, ".git")))
	{
		git(["init", "-q"]);
		git(["remote", "add", "origin", repository]);
	}
	if (auto ret = git(["fetch", "-a"]))
	{
		logInfo("Fetch returned %s", ret);
		return null;
	}

	git(["reset", "--hard", "HEAD"]);

	foreach_reverse (i, ref ver; versions)
	{
		if (addedVersions.canFind!(a => a.commit == ver.commit))
		{
			logDiagnostic("Skipped commit %s", ver.commit.toHexString);
			continue;
		}
		try
		{
			if (git(["checkout", ver.commit.toHexString]) == 0)
			{
				auto projId = ProjectIdentifier(projectID, cast(ubyte[]) ver.commit);
				symbols ~= makeProjectSymbols(path, projId);
				processed ~= cast() ver;
			}
			else
			{
				logError("Exception checking out %s (%s) %s", dubName, projectID, ver.commit.toHexString);
				toRemove ~= cast(ubyte[]) ver.commit;
			}
		}
		catch (Exception e)
		{
			logError("Exception in version check for %s (%s) %s: %s", dubName,
					projectID, ver.commit.toHexString, e);
		}
	}

	return new SymbolIndexResult(toRemove, processed, symbols);
}

Symbol[] makeProjectSymbols(string path, ProjectIdentifier project)
{
	auto output = pipe();
	auto pid = spawnProcess(["dscanner", "--ctags"], nullIn, output.writeEnd,
			stderr, null, Config.none, path);
	Symbol[] ret;
	string[string] packageLookup;
	ubyte[1024 * 4] buffer = void;
	ubyte[1024 * 4] readBuffer = void;
	sleep(20.msecs);
	foreach (line; output.readEnd.byLine)
	{
		if (line.startsWith("!"))
			continue;
		auto symb = Symbol.fromCTag(line.strip);
		symb.bsonID = BsonObjectID.generate;
		if (auto p = symb.file in packageLookup)
			symb.package_ = *p;
		else
		{
			string pkg;
			auto dPath = chainPath(path, symb.file);
			if (exists(dPath))
			{
				foreach (chunk; File(dPath, "rb").byChunk(buffer[]))
				{
					if (!(cast(char[]) chunk).canFind("module"))
						break; // don't even bother if there isn't the text "module"
					auto semicolon = (cast(char[]) chunk).lastIndexOf(';');
					if (semicolon == -1)
						break; // don't bother if there is no semicolon in the file.
					chunk = chunk[0 .. semicolon + 1];
					auto input = pipe();
					auto modout = pipe();
					auto p2 = spawnProcess(["dscanner", "--ast", "stdin"], input.readEnd,
							modout.writeEnd, stderr);
					input.writeEnd.rawWrite(chunk);
					input.writeEnd.flush();
					input.close();
					bool inDecl = false;
					foreach (xml; modout.readEnd.byLine)
					{
						xml = xml.strip;
						if (xml == "<moduleDeclaration>")
							inDecl = true;
						else if (xml == "</moduleDeclaration>")
							break;
						else if (inDecl && xml.startsWith("<identifier>") && xml.endsWith("</identifier>"))
						{
							if (pkg.length)
								pkg ~= ".";
							pkg ~= xml["<identifier>".length .. $ - "</identifier>".length].strip;
						}
					}
					while (!modout.readEnd.eof)
						modout.readEnd.rawRead(readBuffer[]);
					modout.close();
					auto status = p2.wait();
					if (status != 0)
					{
						logInfo("dscanner --ast stdin crashed with %s on input '%s'", status, cast(char[]) chunk);
					}
					break;
				}
			}
			packageLookup[symb.file] = symb.package_ = pkg;
		}
		symb.project = project;
		if (symb.kind == Symbol.Kind.funcDecl && ret.length && ret[$ - 1].symbol == symb.symbol)
			ret[$ - 1].overloads ~= symb.overloads;
		else
			ret ~= symb;

		sleep(100.hnsecs);
	}
	while (!pid.tryWait.terminated)
		sleep(1.msecs);
	return ret;
}
