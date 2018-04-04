module symbolsearch.project;

import std.algorithm;
import std.conv;
import std.string;

struct Symbol
{
	enum Kind : char
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

	enum Access : ubyte
	{
		// all of these must end with _
		public_,
		protected_,
		private_
	}

	string package_;
	string symbol;
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
}
