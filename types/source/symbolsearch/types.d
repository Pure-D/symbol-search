module symbolsearch.types;

import vibe.data.bson;
import vibe.db.mongo.collection;

import std.algorithm;
import std.conv;
import std.datetime;
import std.digest;
import std.string;

import mongoschema;

struct ProjectIdentifier
{
	BsonObjectID project;
	@binaryType(BsonBinData.Type.md5) ubyte[] commit;
}

struct Symbol
{
	enum Kind : int
	{
		enumDecl = 'g',
		enumMember = 'e',
		variable = 'v',
		interfaceDecl = 'i',
		classDecl = 'c',
		structDecl = 's',
		funcDecl = 'f',
		unionDecl = 'u',
		templateDecl = 'T',
		aliasDecl = 'a'
	}

	enum Access : int
	{
		// all of these must end with _
		public_,
		protected_,
		private_
	}

	ProjectIdentifier project;
	string package_;
	@mongoForceIndex string symbol;
	Kind kind;
	string file;
	size_t line;
	Access access;
	Kind parentKind;
	string parent;
	string[] overloads;

	static Symbol fromCTag(in char[] ctag)
	{
		auto parts = ctag.splitter("\t");
		Symbol ret;
		if (parts.empty)
			return ret;
		ret.symbol = parts.front.idup;
		parts.popFront;
		if (parts.empty)
			return ret;
		ret.file = parts.front.idup;
		parts.popFront;
		if (parts.empty)
			return ret;
		parts.popFront;
		if (parts.empty)
			return ret;
		if (parts.front.length != 1)
			return ret;
		ret.kind = cast(Kind) parts.front[0];
		foreach (attr; parts)
		{
			//dfmt off
			auto i = attr.startsWith(
				/* 1 */ "line:",
				/* 2 */ "access:",
				/* 3 */ "signature:",
				"struct:", "enum:", "class:", "interface:", "union:", "template:");
			//dfmt on
			if (!i)
				continue;
			if (i == 1)
				ret.line = attr["line:".length .. $].to!size_t;
			else if (i == 2)
				ret.access = (attr["access:".length .. $] ~ '_').to!Access;
			else if (i == 3)
				ret.overloads = [attr["signature:".length .. $].idup];
			else
			{
				auto attribute = attr.findSplit(":");
				switch (attribute[0])
				{
				case "struct":
					ret.parentKind = Kind.structDecl;
					break;
				case "enum":
					ret.parentKind = Kind.enumDecl;
					break;
				case "class":
					ret.parentKind = Kind.classDecl;
					break;
				case "interface":
					ret.parentKind = Kind.interfaceDecl;
					break;
				case "union":
					ret.parentKind = Kind.unionDecl;
					break;
				case "template":
					ret.parentKind = Kind.templateDecl;
					break;
				default:
					assert(false);
				}
				ret.parent = attribute[2].idup;
			}
		}
		return ret;
	}

@ignore:
	mixin MongoSchema;
}

struct ProjectDescription
{
	struct DBVersion
	{
		SchemaDate date;
		string name;
		@binaryType(BsonBinData.Type.md5) ubyte[] commit;
		Bson info;
	}

	struct DubProject
	{
		struct Version
		{
			SysTime date;
			string version_;
			string commitID;
			Json info;
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

		BsonObjectID _id;
		string owner;
		string name;
		Repository repository;
		@schemaIgnore Version[] versions;
	}

	DubProject dub;
	DBVersion[] versions;

	void versionsFromDub() @safe
	{
		versions.length = dub.versions.length;
		foreach (i, ref ver; versions)
			ver = DBVersion(SchemaDate.fromSysTime(dub.versions[i].date),
					dub.versions[i].version_, dub.versions[i].commitID.commitMd5,
					Bson.fromJson(dub.versions[i].info));
	}

	DBVersion latestVersion() @safe
	{
		return versions.maxElement!(a => a.date.time);
	}

	ProjectIdentifier latestIdentifier() @safe
	{
		return ProjectIdentifier(bsonID, latestVersion.commit);
	}

@ignore:
	mixin MongoSchema;
}

ubyte[] commitMd5(string hex) @safe
{
	if (hex.length < 32)
	{
		char[32] c = '0';
		c[$ - hex.length .. $] = hex;
		hex = c[].idup;
	}
	ubyte[16] ret;
	for (int i = 0; i < 16; i++)
		ret[i] = hex[i * 2 .. i * 2 + 2].to!ubyte(16);
	return ret[].dup;
}

struct APISymbol
{
	string project;
	string package_;
	string symbol;
	Symbol.Kind kind;
	string file;
	size_t line;
	Symbol.Access access;
	Symbol.Kind parentKind;
	string parent;
	string[] overloads;

	static APISymbol fromSymbol(Symbol symbol, string project)
	{
		APISymbol ret;
		ret.project = project;
		static foreach (member; ["package_", "symbol", "kind", "file", "line", "access", "parentKind", "parent", "overloads"])
			mixin("ret." ~ member) = mixin("symbol." ~ member);
		return ret;
	}
}

struct APIProjectByPackage
{
	struct Version
	{
		SysTime date;
		string name;
		string commit;
		Json info;
	}

	@ignore BsonObjectID id;
	ProjectDescription.DubProject dub;
	Version[] versions;
	string[] packages;

	static APIProjectByPackage fromProject(ProjectDescription project)
	{
		APIProjectByPackage ret;
		ret.id = project.bsonID;
		ret.dub = project.dub;
		foreach (ver; project.versions)
			ret.versions ~= Version(ver.date.toSysTime, ver.name, ver.commit.toHexString, ver.info.toJson);
		return ret;
	}
}

interface ISymbolSearchAPI
{
	APISymbol[] getSymbols(string identifier, bool exact = true, string kind = "gevicsfuTa", string access = "+*-", string[] projects = [], size_t limit = 1000, size_t page = 0) @safe;
	APIProjectByPackage[] getProjectsByPackage(string package_) @safe;
}
