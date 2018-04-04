module symbolsearch.mksymbols;

import std.algorithm;
import std.array;
import std.datetime;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.data.json;
import vibe.data.bson;
import vibe.http.client;

import rm.rf;

import symbolsearch.project;

struct ProjectDescription
{
	struct Version
	{
		SysTime date;
		string version_;
		string commitID;
		Json info;

	@optional:
		Symbol[] symbols;
	}

	struct Repository
	{
		string kind, owner, project;

		string gitURL() const @property
		{
			switch (kind)
			{
			case "github":
				return "https://github.com/" ~ owner ~ "/" ~ project ~ ".git";
			case "gitlab":
				return "https://gitlab.com/" ~ owner ~ "/" ~ project ~ ".git";
			case "bitbucket":
				return "https://bitbucket.org/" ~ owner ~ "/" ~ project;
			default:
				throw new Exception("Unsupported project kind " ~ kind);
			}
		}
	}

	string owner;
	string name;
	Repository repository;
	Version[] versions;
@optional:
	Symbol[] allSymbols;
}

ProjectDescription[] fetchDubProjects()
{
	Json data;
	bool found;
	for (int i = 0; i < 5 && !found; i++)
	{
		requestHTTP("https://code.dlang.org/api/packages/dump", (scope req) {  }, (scope res) {
			if (res.statusCode != 200)
				return;
			data = res.readJson;
			found = true;
		});
		if (!found)
			sleep(5.seconds);
	}
	if (!found)
		throw new Exception("dub package dump not found");
	return data.deserializeJson!(ProjectDescription[]);
}

void indexAllProjects()
{
	foreach (project; fetchDubProjects)
		runWorkerTask(&indexProject, cast(shared) project);
}

void indexProject(shared ProjectDescription sproject)
{
	auto project = cast() sproject;
	ProjectDescription existing; // TODO: monogodb search
	auto vers = existing.versions;
	existing = project;
	existing.versions = vers;
	existing.allSymbols = [];
	auto path = buildPath(tempDir, "ss-clones", project.name);
	if (exists(path))
		rmdirRecurseForce(path);
	mkdirRecurse(path);
	scope (exit)
		rmdirRecurseForce(path);

	void git(string[] args)
	{
		auto ret = spawnProcess("git" ~ args, null, Config.none, path).wait;
		if (ret != 0)
			throw new Exception("git " ~ args.join(" ") ~ " has failed");
	}

	git(["init"]);
	git(["remote", "add", "origin", project.repository.gitURL]);
	git(["fetch", "-a"]);

	foreach_reverse (i, ref ver; project.versions)
	{
		if (existing.versions.canFind!(a => a.commitID == ver.commitID))
			continue;
		try
		{
			git(["checkout", ver.commitID]);
			ver.symbols = listProjectSymbols(path);
		}
		catch (Exception e)
		{
			project.versions[i .. $ - 1] = project.versions[i + 1 .. $];
			project.versions.length--;
		}
	}

	existing.versions = project.versions;
	//dfmt off
	existing.allSymbols = existing.versions
		.map!(a => a.symbols)
		.joiner
		.array
		.sort!"a.symbol < b.symbol"
		.chunkBy!"a.symbol"
		.map!((a) {
			Symbol ret = a[1].front;
			ret.overloads = a[1].map!"a.overloads".joiner.array.sort!"a<b".uniq.array;
			return ret;
		})
		.array;
	//dfmt on

	import std.stdio;

	writeln(existing);
}

Symbol[] listProjectSymbols(string path)
{
	auto output = pipe();
	auto pid = spawnProcess(["dscanner", "--ctags"], stdin, output.writeEnd,
			stderr, null, Config.none, path);
	Symbol[] ret;
	foreach (line; output.readEnd.byLine)
	{
		auto symb = Symbol.fromCTag(line.strip);
		if (symb.kind == Symbol.Kind.funcDecl && ret.length && ret[$ - 1].symbol == symb.symbol)
			ret[$ - 1].overloads ~= symb.overloads[0];
		else
			ret ~= symb;
	}
	pid.wait();
	return ret;
}
