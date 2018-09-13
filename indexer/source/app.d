import vibe.vibe;

import symbolsearch.types;
import symbolsearch.mksymbols;

import mongoschema;

void main(string[] args)
{
	if (args.length < 2 || args[1] == "-h" || args[1] == "--h" || args[1] == "--help")
	{
		logInfo("Usage: " ~ args[0] ~ " [host] [db]");
		logInfo("Run this program in a crontab every hour or so to re-index all projects");
		return;
	}

	auto conn = connectMongoDB(args[1]); // "mongodb://127.0.0.1"
	auto db = conn.getDatabase(args[2]); // "symbolsearch"

	db["projects"].register!ProjectDescription;
	db["symbols"].register!Symbol;

	indexAllProjects();
}
