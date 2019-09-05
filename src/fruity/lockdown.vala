namespace Frida.Fruity {
	public class LockdownClient : Object, AsyncInitable {
		public DeviceDetails device_details {
			get;
			construct;
		}

		private PlistServiceClient service;
		private Promise<bool>? pending_service_query;

		private const uint16 LOCKDOWN_PORT = 62078;

		private LockdownClient (DeviceDetails device_details) {
			Object (device_details: device_details);
		}

		public static async LockdownClient open (DeviceDetails device_details, Cancellable? cancellable = null)
				throws LockdownError, IOError {
			var client = new LockdownClient (device_details);

			try {
				yield client.init_async (Priority.DEFAULT, cancellable);
			} catch (GLib.Error e) {
				throw_local_error (e);
			}

			return client;
		}

		private async bool init_async (int io_priority, Cancellable? cancellable) throws LockdownError, IOError {
			var device = device_details;

			try {
				var usbmux = yield UsbmuxClient.open (cancellable);

				var pair_record = yield usbmux.read_pair_record (device.udid, cancellable);

				yield usbmux.connect_to_port (device.id, LOCKDOWN_PORT, cancellable);

				service = new PlistServiceClient (usbmux.connection);

				yield query_type (cancellable);

				yield start_session (pair_record, cancellable);
			} catch (UsbmuxError e) {
				throw new IOError.FAILED ("%s", e.message);
			}

			return true;
		}

		public async void close (Cancellable? cancellable = null) throws IOError {
			yield service.close (cancellable);
		}

		public async IOStream start_service (string name, Cancellable? cancellable = null) throws LockdownError, IOError {
			Plist request = create_request ("StartService");
			request.set_string ("Service", name);

			Plist? response = null;
			while (pending_service_query != null) {
				var future = pending_service_query.future;
				try {
					yield future.wait_async (cancellable);
				} catch (GLib.Error e) {
				}
				cancellable.set_error_if_cancelled ();
			}
			pending_service_query = new Promise<bool> ();
			try {
				response = yield service.query (request, cancellable);
			} catch (PlistServiceError e) {
				throw error_from_service (e);
			} finally {
				pending_service_query = null;
			}

			try {
				if (response.has ("Error")) {
					var error = response.get_string ("Error");
					if (error == "InvalidService")
						throw new LockdownError.INVALID_SERVICE ("Service '%s' not found", name);
					else
						throw new LockdownError.PROTOCOL ("Unexpected response: %s", error);
				}

				var service_transport = yield UsbmuxClient.open (cancellable);
				yield service_transport.connect_to_port (device_details.id, (uint16) response.get_integer ("Port"),
					cancellable);

				return service_transport.connection;
			} catch (PlistError e) {
				throw error_from_plist (e);
			} catch (UsbmuxError e) {
				throw new IOError.FAILED ("%s", e.message);
			}
		}

		private async string query_type (Cancellable? cancellable) throws LockdownError, IOError {
			try {
				var response = yield service.query (create_request ("QueryType"), cancellable);

				return response.get_string ("Type");
			} catch (PlistServiceError e) {
				throw error_from_service (e);
			} catch (PlistError e) {
				throw error_from_plist (e);
			}
		}

		private async void start_session (Plist pair_record, Cancellable? cancellable) throws LockdownError, IOError {
			string host_id, system_buid;
			try {
				host_id = pair_record.get_string ("HostID");
				system_buid = pair_record.get_string ("SystemBUID");
			} catch (PlistError e) {
				throw new LockdownError.PROTOCOL ("Invalid pair record: %s", e.message);
			}

			try {
				var request = create_request ("StartSession");
				request.set_string ("HostID", host_id);
				request.set_string ("SystemBUID", system_buid);

				var response = yield service.query (request, cancellable);
				if (response.has ("Error"))
					throw new LockdownError.PROTOCOL ("Unexpected response: %s", response.get_string ("Error"));

				if (response.get_boolean ("EnableSessionSSL"))
					yield service.enable_encryption (pair_record, cancellable);
			} catch (PlistServiceError e) {
				throw error_from_service (e);
			} catch (PlistError e) {
				throw error_from_plist (e);
			}
		}

		private static Plist create_request (string request_type) {
			var request = new Plist ();
			request.set_string ("Request", request_type);
			request.set_string ("Label", "Xcode");
			request.set_string ("ProtocolVersion", "2");
			return request;
		}

		private static void throw_local_error (GLib.Error e) throws LockdownError, IOError {
			if (e is LockdownError)
				throw (LockdownError) e;

			if (e is IOError)
				throw (IOError) e;

			assert_not_reached ();
		}

		private static LockdownError error_from_service (PlistServiceError e) {
			return new LockdownError.PROTOCOL ("%s", e.message);
		}

		private static LockdownError error_from_plist (PlistError e) {
			return new LockdownError.PROTOCOL ("Unexpected response: %s", e.message);
		}
	}

	public errordomain LockdownError {
		INVALID_SERVICE,
		PROTOCOL
	}
}