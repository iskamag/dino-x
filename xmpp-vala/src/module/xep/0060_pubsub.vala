using Gee;

namespace Xmpp.Xep.Pubsub {
    public const string NS_URI = "http://jabber.org/protocol/pubsub";
    private const string NS_URI_EVENT = NS_URI + "#event";
    private const string NS_URI_OWNER = NS_URI + "#owner";
    public const string NS_URI_ERROR = NS_URI + "#errors";

    public const string ACCESS_MODEL_AUTHORIZE = "authorize";
    public const string ACCESS_MODEL_OPEN = "open";
    public const string ACCESS_MODEL_PRESENCE = "presence";
    public const string ACCESS_MODEL_ROSTER = "roster";
    public const string ACCESS_MODEL_WHITELIST = "whitelist";

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0060_pubsub_module");

        private HashMap<string, ItemListenerDelegate> item_listeners = new HashMap<string, ItemListenerDelegate>();
        private HashMap<string, RetractListenerDelegate> retract_listeners = new HashMap<string, RetractListenerDelegate>();
        private HashMap<string, DeleteListenerDelegate> delete_listeners = new HashMap<string, DeleteListenerDelegate>();

        public void add_filtered_notification(XmppStream stream, string node,
                owned ItemListenerDelegate.ResultFunc? item_listener,
                owned RetractListenerDelegate.ResultFunc? retract_listener,
                owned DeleteListenerDelegate.ResultFunc? delete_listener) {
            stream.get_module(ServiceDiscovery.Module.IDENTITY).add_feature_notify(stream, node);
            if (item_listener != null) {
                item_listeners[node] = new ItemListenerDelegate((owned)item_listener);
            }
            if (retract_listener != null) {
                retract_listeners[node] = new RetractListenerDelegate((owned)retract_listener);
            }
            if (delete_listener != null) {
                delete_listeners[node] = new DeleteListenerDelegate((owned)delete_listener);
            }
        }

        public void remove_filtered_notification(XmppStream stream, string node) {
            stream.get_module(ServiceDiscovery.Module.IDENTITY).remove_feature_notify(stream, node);
            item_listeners.unset(node);
            retract_listeners.unset(node);
        }

        public async Gee.List<StanzaNode>? request_all(XmppStream stream, Jid? jid, string node) { // TODO multiple nodes gehen auch
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(new StanzaNode.build("items", NS_URI).put_attribute("node", node)));
            if (jid != null) request_iq.to = jid;

            Iq.Stanza iq_res = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, request_iq);

            StanzaNode event_node = iq_res.stanza.get_subnode("pubsub", NS_URI);
            if (event_node == null) return null;
            StanzaNode items_node = event_node.get_subnode("items", NS_URI);
            if (items_node == null) return null;

            return items_node.get_subnodes("item", NS_URI);
        }

        public delegate void OnResult(XmppStream stream, Jid? jid, string? id, StanzaNode? node, bool success);

        // Bounded wait for a PEP response. Without it a dropped IQ leaves the
        // caller (e.g. the OMEMO device-list future) pending forever.
        private const int REQUEST_TIMEOUT_SECONDS = 30;

        // Readable/writable so tests can lower the timeout (0 disables it).
        public int request_timeout_seconds { get; set; default = REQUEST_TIMEOUT_SECONDS; }

        private class RequestContext : Object {
            public OnResult listener;
            public bool finished = false;
            public uint timeout_id = 0;

            public RequestContext(owned OnResult listener) {
                this.listener = (owned) listener;
            }
        }

        public void request(XmppStream stream, Jid? jid, string node, owned OnResult listener) { // TODO multiple nodes gehen auch
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(new StanzaNode.build("items", NS_URI).put_attribute("node", node)));
            if (jid != null) request_iq.to = jid;

            var context = new RequestContext((owned) listener);
            var cancellable = new Cancellable();
            if (request_timeout_seconds <= 0) {
                stream.get_module(Iq.Module.IDENTITY).send_iq_async.begin(stream, request_iq, Priority.DEFAULT, cancellable, (obj, res) => {
                    handle_request_result(stream, jid, node, context, obj, res);
                });
                return;
            }

            context.timeout_id = Timeout.add_seconds((uint) request_timeout_seconds, () => {
                context.timeout_id = 0;
                if (!context.finished) {
                    context.finished = true;
                    debug("Pubsub request for %s timed out", node);
                    // Make sure the caller is released even if the write never
                    // completes or the stream disappears mid-request.
                    context.listener(stream, jid, null, null, false);
                }
                cancellable.cancel();
                return false;
            });

            stream.get_module(Iq.Module.IDENTITY).send_iq_async.begin(stream, request_iq, Priority.DEFAULT, cancellable, (obj, res) => {
                handle_request_result(stream, jid, node, context, obj, res);
            });
        }

        private void handle_request_result(XmppStream stream, Jid? requested_jid, string node, RequestContext context, Object? source, AsyncResult res) {
            if (context.finished) return;
            context.finished = true;
            if (context.timeout_id != 0) {
                Source.remove(context.timeout_id);
                context.timeout_id = 0;
            }

            Iq.Stanza? iq_result = null;
            try {
                iq_result = stream.get_module(Iq.Module.IDENTITY).send_iq_async.end(res);
            } catch (IOError e) {
                debug("Pubsub request for %s failed: %s", node, e.message);
            }

            StanzaNode? item_node = null;
            string? id = null;
            bool success = false;
            if (iq_result != null) {
                StanzaNode? event_node = iq_result.stanza.get_subnode("pubsub", NS_URI);
                StanzaNode? items_node = event_node != null ? event_node.get_subnode("items", NS_URI) : null;
                item_node = items_node != null ? items_node.get_subnode("item", NS_URI) : null;
                id = item_node != null ? item_node.get_attribute("id", NS_URI) : null;
                success = !iq_result.is_error();
            }

            Jid? from_jid = iq_result != null ? iq_result.from : null;
            if (from_jid == null) from_jid = requested_jid;
            if (from_jid == null) {
                Bind.Flag? bind_flag = stream.get_flag(Bind.Flag.IDENTITY);
                if (bind_flag != null) from_jid = bind_flag.my_jid;
            }

            context.listener(stream, from_jid, id,
                item_node != null && item_node.sub_nodes.size > 0 ? item_node.sub_nodes[0] : null, success);
        }

        public async bool publish(
                XmppStream stream, Jid? jid, string node_id, string? item_id, StanzaNode content,
                PublishOptions? publish_options = null,
                bool try_reconfiguring = true
        ) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("publish", NS_URI).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            StanzaNode items_node = new StanzaNode.build("item", NS_URI);
            if (item_id != null) items_node.put_attribute("id", item_id);
            items_node.put_node(content);
            publish_node.put_node(items_node);

            // Send along our requirements for the node
            if (publish_options != null) {
                StanzaNode publish_options_node = new StanzaNode.build("publish-options", NS_URI);
                pubsub_node.put_node(publish_options_node);

                DataForms.DataForm data_form = new DataForms.DataForm();
                DataForms.DataForm.HiddenField form_type_field = new DataForms.DataForm.HiddenField() { var="FORM_TYPE" };
                form_type_field.set_value_string(NS_URI + "#publish-options");
                data_form.add_field(form_type_field);

                foreach (string field_name in publish_options.settings.keys) {
                    DataForms.DataForm.Field field = new DataForms.DataForm.Field() { var=field_name };
                    field.set_value_string(publish_options.settings[field_name]);
                    data_form.add_field(field);
                }
                publish_options_node.put_node(data_form.get_submit_node());
            }

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            if (jid != null) iq.to = jid;

            // If the node was configured differently before, reconfigure it to meet our requirements and try again
            Iq.Stanza iq_result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            if (iq_result.is_error()) {
                if (publish_options == null || !try_reconfiguring) return false;
                bool precondition_not_met = iq_result.get_error().error_node.get_subnode("precondition-not-met", NS_URI_ERROR) != null;
                if (precondition_not_met) {
                    bool success = yield change_node_config(stream, jid, node_id, publish_options);
                    if (!success) return false;
                    return yield publish(stream, jid, node_id, item_id, content, publish_options, false);
                }
            }

            return true;
        }

        public async bool retract_item(XmppStream stream, Jid? jid, string node_id, string item_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("retract", NS_URI).put_attribute("node", node_id).put_attribute("notify", "true")
                    .put_node(new StanzaNode.build("item", NS_URI).put_attribute("id", item_id)));

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            try {
                Iq.Stanza result_iq = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
                return !result_iq.is_error();
            } catch (IOError e) {
                return false;
            }
        }

        public void delete_node(XmppStream stream, Jid? jid, string node_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("delete", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            stream.get_module(Iq.Module.IDENTITY).send_iq(stream, iq, null);
        }

        public async DataForms.DataForm? request_node_config(XmppStream stream, Jid? jid, string node_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.get(pubsub_node);
            Iq.Stanza result_iq = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            StanzaNode? data_form_node = result_iq.stanza.get_deep_subnode(Pubsub.NS_URI_OWNER + ":pubsub", Pubsub.NS_URI_OWNER + ":configure", "jabber:x:data:x");
            if (data_form_node == null) return null;
            return DataForms.DataForm.create_from_node(data_form_node);
        }

        public async bool submit_node_config(XmppStream stream, DataForms.DataForm data_form, string node_id) {
            StanzaNode submit_node = data_form.get_submit_node();

            StanzaNode pubsub_node = new StanzaNode.build("pubsub", Pubsub.NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", Pubsub.NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            publish_node.put_node(submit_node);


            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            Iq.Stanza iq_result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);

            return !iq_result.is_error();
        }

        public override void attach(XmppStream stream) {
            stream.get_module(MessageModule.IDENTITY).received_message.connect(on_received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        private void on_received_message(XmppStream stream, MessageStanza message) {
            StanzaNode event_node = message.stanza.get_subnode("event", NS_URI_EVENT);
            if (event_node == null) return;

            if (!message.from.is_bare()) {
                warning("Got a PEP message from a full JID (%s), ignoring.", message.from.to_string());
                return;
            }

            StanzaNode items_node = event_node.get_subnode("items", NS_URI_EVENT);
            if (items_node != null) {
                string node = items_node.get_attribute("node", NS_URI_EVENT);

                StanzaNode? item_node = items_node.get_subnode("item", NS_URI_EVENT);
                if (item_node != null) {
                    string id = item_node.get_attribute("id", NS_URI_EVENT);

                    if (item_listeners.has_key(node)) {
                        item_listeners[node].on_result(stream, message.from, id, item_node.sub_nodes.size > 0 ? item_node.sub_nodes[0] : null);
                    }
                }

                StanzaNode? retract_node = items_node.get_subnode("retract", NS_URI_EVENT);
                if (retract_node != null) {
                    string id = retract_node.get_attribute("id", NS_URI_EVENT);

                    if (retract_listeners.has_key(node)) {
                        retract_listeners[node].on_result(stream, message.from, id);
                    }
                }
            }

            StanzaNode? delete_node = event_node.get_subnode("delete", NS_URI_EVENT);
            if (delete_node != null) {
                string node = delete_node.get_attribute("node", NS_URI_EVENT);

                if (delete_listeners.has_key(node)) {
                    delete_listeners[node].on_result(stream, message.from);
                }
            }
        }

        private async bool change_node_config(XmppStream stream, Jid jid, string node, PublishOptions publish_options) {
            DataForms.DataForm? data_form = yield stream.get_module(Pubsub.Module.IDENTITY).request_node_config(stream, jid, node);
            if (data_form == null) return false;

            foreach (DataForms.DataForm.Field field in data_form.fields) {
                if (publish_options.settings.has_key(field.var) && publish_options.settings[field.var] != field.get_value_string()) {
                    field.set_value_string(publish_options.settings[field.var]);
                }
            }
            return yield stream.get_module(Pubsub.Module.IDENTITY).submit_node_config(stream, data_form, node);
        }
    }

    public class PublishOptions {
        public HashMap<string, string> settings = new HashMap<string, string>();

        public PublishOptions set_persist_items(bool persist) {
            settings["pubsub#persist_items"] = persist.to_string();
            return this;
        }

        public PublishOptions set_max_items(string max) {
            settings["pubsub#max_items"] = max;
            return this;
        }

        public PublishOptions set_send_last_published_item(string send) {
            settings["pubsub#send_last_published_item"] = send.to_string();
            return this;
        }

        public PublishOptions set_access_model(string model) {
            settings["pubsub#access_model"] = model;
            return this;
        }
    }

    public class ItemListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id, StanzaNode? node);
        public ResultFunc on_result { get; private owned set; }

        public ItemListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class RetractListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id);
        public ResultFunc on_result { get; private owned set; }

        public RetractListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class DeleteListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid);
        public ResultFunc on_result { get; private owned set; }

        public DeleteListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

}
