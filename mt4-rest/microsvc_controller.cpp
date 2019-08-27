
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>

#include "stdafx.h"
#include "microsvc_controller.hpp"
#include "types.hpp"

#define CMD_VERSION L"version"

using namespace web;
using namespace http;

void MicroserviceController::initRestOpHandlers() {
	_listener.support(methods::GET, std::bind(&MicroserviceController::handleGet, this, std::placeholders::_1));
	_listener.support(methods::PUT, std::bind(&MicroserviceController::handlePut, this, std::placeholders::_1));
	_listener.support(methods::POST, std::bind(&MicroserviceController::handlePost, this, std::placeholders::_1));
	_listener.support(methods::DEL, std::bind(&MicroserviceController::handleDelete, this, std::placeholders::_1));
	_listener.support(methods::PATCH, std::bind(&MicroserviceController::handlePatch, this, std::placeholders::_1));
	_listener.support(methods::HEAD, std::bind(&MicroserviceController::handleHead, this, std::placeholders::_1));

	pushCommand(L"inited", endpoint());
}

void MicroserviceController::pushCommand(string_t command, string_t options) {

	web::json::value result = web::json::value::object();

	result[U("command")] = web::json::value::string(command);
	result[U("options")] = web::json::value::string(options);

	commands.push_back(ws2s(result.serialize()));
}

const char* MicroserviceController::getCommand() {
	string command;

	if (commands.size() < 1)
		return NULL;

	command.append(commands.back());
	commands.pop_back();

	return command.c_str();
}

int MicroserviceController::hasCommands() {
	return commands.size() > 0;
}


void MicroserviceController::setCommandResponse(const char* command, const char* response) {
	commandResponses[command] = response;
}

void MicroserviceController::setCommandWaitTimeout(int timeout) {
	wait_timeout = timeout*1000;
}

auto MicroserviceController::formatError(int code, const utility::string_t message) {
	web::json::value result = web::json::value::object();

	result[U("message")] = web::json::value::string(message);
	result[U("code")] = web::json::value::number(code);

	return result;
}

auto MicroserviceController::formatError(int code, const char* message) {
	wstring msg(message, message + strlen(message));

	return formatError(code, msg);
}

auto MicroserviceController::formatErrorRequired(utility::string_t field) {
	utility::string_t msg(field);

	msg.append(U(" is required"));

	return formatError(402, msg);
}

void MicroserviceController::handleGet(http_request message) {
	auto response = json::value::object();
	auto path = requestPath(message);
	auto params = requestQueryParams(message);
	auto headers = message.headers();

	try {

		web::json::value result = web::json::value::object();
		web::json::value jQuery = web::json::value::object(params.size());
		web::json::value jPath = web::json::value::array(path.size());
		web::json::value jHeader = web::json::value::array(headers.size());

		int idx = 0;
		for (auto it = path.begin(); it != path.end(); ++it) {			
			jPath[idx] = web::json::value::string(path[idx]);
			idx++;
		}
		result[L"path"] = jPath;

		/*for (auto it = params.begin(); it != params.end(); ++it) {
			jQuery[it->first] = web::json::value::string(it->second);
		}
		result[L"query"] = jQuery; 
		*/

		for (auto it = headers.begin(); it != headers.end(); ++it) {
			jHeader[it->first] = web::json::value::string(it->second);
		}
		result[L"header"] = jHeader;

		result[L"host"] = web::json::value::string(headers[header_names::host]);

		string command = ws2s(result.serialize());
		commands.push_back(command);

		DWORD dw1 = GetTickCount();

		while(dw1 + wait_timeout > GetTickCount()) {

			if (commandResponses.contains(command)) {					
				message.reply(status_codes::OK, commandResponses[command], "application/json");
				commandResponses.remove(command);
				return;
			}

			Sleep(1);
		}

		throw exception("Failed to get mt4 response, timeout");
	}
	catch (const FormatException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const RequiredException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const json::json_exception & e) {
		message.reply(status_codes::BadRequest, formatError(410, e.what()));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		message.reply(status_codes::BadRequest, formatError(410, ex.what()));
		ucout << ex.what() << endl;
	}
	catch (...) {
		message.reply(status_codes::InternalError);
	}
}

void MicroserviceController::handlePost(http_request message) {
	auto response = json::value::object();

	try {

		auto path = requestPath(message);
		auto params = requestQueryParams(message);		

		ucout << message.to_string() << endl;

		message.extract_utf8string(true).then([=](std::string body) {
			auto headers = message.headers();

			web::json::value result = web::json::value::object();
			web::json::value jPath = web::json::value::array(path.size());
			web::json::value jHeader = web::json::value::array(headers.size());
			web::json::value jQuery = web::json::value::object(params.size());

			int idx = 0;
			for (auto it = path.begin(); it != path.end(); ++it) {
				jPath[idx] = web::json::value::string(path[idx]);
				idx++;
			}
			result[L"path"] = jPath;

			for (auto it = params.begin(); it != params.end(); ++it) {
				jQuery[it->first] = web::json::value::string(it->second);
			}
			result[L"query"] = jQuery;
			
			/*for (auto it = headers.begin(); it != headers.end(); ++it) {
				if(!it->first.empty() && !it->second.empty())
					jHeader[it->first] = web::json::value::string(it->second);
			}
			result[L"header"] = jHeader; */

			
			result[L"host"] = web::json::value::string(headers[header_names::host]);

			result[L"body"] = web::json::value::string(s2ws(body));

			string command = ws2s(result.serialize());
			commands.push_back(command);

			DWORD dw1 = GetTickCount();

			while (dw1 + wait_timeout > GetTickCount()) {

				if (commandResponses.contains(command)) {
					message.reply(status_codes::OK, commandResponses[command], "application/json");
					commandResponses.remove(command);
					return;
				}

				Sleep(1);
			}

			throw exception("Failed to get mt4 response, timeout");

		}).wait();

	}
	catch (const ManagerException & e) {
		message.reply(status_codes::BadRequest, formatError(e.code, e.what()));
	}
	catch (const FormatException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const RequiredException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const json::json_exception & e) {
		message.reply(status_codes::BadRequest, formatError(410, e.what()));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		message.reply(status_codes::BadRequest, formatError(410, ex.what()));
		ucout << ex.what() << endl;
	}
	catch (...) {
		message.reply(status_codes::InternalError);
	}

}

void MicroserviceController::handleDelete(http_request message) {
	try {
		auto path = requestPath(message);
		auto params = requestQueryParams(message);

		if (path.size() < 1) {
			message.reply(status_codes::NotFound);
			return;
		}

	} 
	catch (const ManagerException & e) {
		message.reply(status_codes::BadRequest, formatError(e.code, e.what()));
	}
	catch (const FormatException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const RequiredException & e) {
		message.reply(status_codes::BadRequest, formatError(405, e.what()));
	}
	catch (const json::json_exception & e) {
		message.reply(status_codes::BadRequest, formatError(410, e.what()));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		message.reply(status_codes::BadRequest, formatError(410, ex.what()));
		ucout << ex.what() << endl;
	}
	catch (...) {
		message.reply(status_codes::InternalError);
	}
}

void MicroserviceController::handleHead(http_request message) {
	auto response = json::value::object();
	response[U("version")] = json::value::string(U("0.1.1"));
	response[U("code")] = json::value::number(200);
	message.reply(status_codes::OK, "version");
}

void MicroserviceController::handleOptions(http_request message) {
	http_response response(status_codes::OK);
	response.headers().add(U("Allow"), U("GET, POST, OPTIONS"));
	response.headers().add(U("Access-Control-Allow-Origin"), U("*"));
	response.headers().add(U("Access-Control-Allow-Methods"), U("GET, POST, OPTIONS"));
	response.headers().add(U("Access-Control-Allow-Headers"), U("Content-Type"));
	message.reply(response);
}

void MicroserviceController::handleTrace(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::TRCE));
}

void MicroserviceController::handleConnect(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::CONNECT));
}

void MicroserviceController::handleMerge(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::MERGE));
}

void MicroserviceController::handlePatch(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::MERGE));
}

void MicroserviceController::handlePut(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::MERGE));
}

json::value MicroserviceController::responseNotImpl(const http::method & method) {

	using namespace json;

	auto response = value::object();
	response[U("serviceName")] = value::string(U("MT4 REST"));
	response[U("http_method")] = value::string(method);

	return response;
}
