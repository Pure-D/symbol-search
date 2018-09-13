module symbolsearch.api;

import std.algorithm;
import std.array;
import std.regex;

import symbolsearch.types;

import vibe.vibe;

import mongoschema;

static immutable DottedIdentifierRegex = ctRegex!`^[a-zA-Z_]\w*(\.[a-zA-Z_]\w*)*$`;

struct ProjectIdentifierMap
{
	ProjectIdentifier id;
	string name;
}

string findProjectName(ProjectIdentifierMap[] map, BsonObjectID id)
{
	foreach (v; map)
		if (v.id.project == id)
			return v.name;
	return ProjectDescription.findById(id).dub.name;
}

class SymbolSearchAPI : ISymbolSearchAPI
{
@safe:
	private auto symbolIterator(string identifier, bool exact, string kind = "gevicsfuTa",
			string access = "+*-", ProjectIdentifierMap[] projects = [], size_t limit = 1000,
			size_t page = 0) @trusted
	{
		//dfmt off
		Bson[string] search = [
			"kind": serializeToBson(["$in": (cast(ubyte[])kind).map!(a => cast(int)a).array]),
			"access": serializeToBson(["$in": access.map!(a =>
				a == '+' ? Symbol.Access.public_ :
				a == '*' ? Symbol.Access.protected_ :
				a == '-' ? Symbol.Access.private_ :
				-1
			).array]),
		];
		if (exact)
			search["symbol"] = Bson(identifier);
		else
			search["symbol"] = serializeToBson(["$regex": identifier, "$options": "i"]);
		if (projects.length)
			search["project"] = Bson(["$in": Bson(projects.map!(a => a.id.toSchemaBson).array)]);
		return Symbol.findRange(search, QueryFlags.none, cast(int)(page * limit)).limit(limit);
		//dfmt on
	}

	private ProjectIdentifierMap[] resolveProjects(string[] projects) @trusted
	{
		ProjectIdentifierMap[] ret;
		foreach (proj; ProjectDescription.findRange(["dub.name" : ["$in" : projects]]))
			ret ~= ProjectIdentifierMap(proj.latestIdentifier, proj.dub.name);
		return ret;
	}

	override APISymbol[] getSymbols(string identifier, bool exact = true,
			string kind = "gevicsfuTa", string access = "+*-", string[] projects = [],
			size_t limit = 1000, size_t page = 0) @trusted
	{
		enforceBadRequest(limit <= 1000, "Can't go over 1000 symbols limit");
		enforceBadRequest(identifier.length > 0
				&& identifier.matchFirst(DottedIdentifierRegex), "Bad identifier given");
		identifier = identifier.replace(`.`, `\.`);
		auto identifiers = resolveProjects(projects);
		return symbolIterator(identifier, exact, kind, access, identifiers, limit, page).map!(
				a => APISymbol.fromSymbol(a, identifiers.findProjectName(a.project.project))).array;
	}

	override APIProjectByPackage[] getProjectsByPackage(string package_) @trusted
	{
		enforceBadRequest(package_.length > 0
				&& package_.matchFirst(DottedIdentifierRegex), "Bad package name given");
		package_ = package_.replace(`.`, `\.`); // because of previous enforceBadRequest there can only be dots as special regex characters in this string
		APIProjectByPackage[] projects;
		foreach (sym; Symbol.findRange(["package_" : ["$regex" : "\\b" ~ package_ ~ "\\b"]]))
		{
			auto existing = projects.countUntil!(a => a.id == sym.project.project);
			if (existing != -1)
			{
				if (!projects[existing].packages.canFind(sym.package_))
					projects[existing].packages ~= sym.package_;
				continue;
			}
			auto proj = APIProjectByPackage.fromProject(ProjectDescription.findById(sym.project.project));
			proj.packages = [sym.package_];
			projects ~= proj;
		}
		return projects;
	}
}
