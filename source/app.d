import vibe.vibe;

import symbolsearch.api;
import symbolsearch.types;

import mongoschema;

void main()
{
	auto conn = connectMongoDB("mongodb://127.0.0.1");
	auto db = conn.getDatabase("symbolsearch");

	db["projects"].register!ProjectDescription;
	db["symbols"].register!Symbol;

	auto settings = new HTTPServerSettings;
	settings.port = 3000;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	auto router = new URLRouter;
	router.registerRestInterface(new SymbolSearchAPI);
	listenHTTP(settings, router);

	runApplication();
}
