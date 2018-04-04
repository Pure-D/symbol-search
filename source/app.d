import vibe.vibe;

import symbolsearch.mksymbols;
import symbolsearch.project;

void main()
{
	auto data = readFileUTF8("dump.json").parseJsonString.deserializeJson!(ProjectDescription[]);

	logInfo("Parsed");
	indexProject(cast(shared) data[0]);

	auto settings = new HTTPServerSettings;
	settings.port = 3000;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, &hello);

	runApplication();
}

void hello(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("Hello World");
}
