using Gee;
using Gdk;
using Gtk;
using Pango;
using Xmpp;

using Dino.Entities;

namespace Dino.Ui {

    public class FileGroupMetaItem : ConversationSummary.ContentMetaItem {

        private StreamInteractor stream_interactor;
        private FileGroupItem file_group_item;

        public FileGroupMetaItem(ContentItem content_item, StreamInteractor stream_interactor) {
            base(content_item);
            this.stream_interactor = stream_interactor;
            this.file_group_item = content_item as FileGroupItem;
        }

        public override Object? get_widget(Plugins.ConversationItemWidgetInterface outer, Plugins.WidgetType type) {
            var file_transfers = file_group_item.file_group.file_transfers;

            if (file_transfers.size > 1 && all_files_images(file_transfers)) {
                return new ImageGroupWidget(file_transfers);
            } else {
                Box box = new Box(Orientation.VERTICAL, 6);
                foreach (FileTransfer file_transfer in file_transfers) {
                    FileWidget widget = new FileWidget(file_transfer) { halign = Align.START };
                    widget.add_css_class("file-image-widget");
                    FileWidgetController widget_controller = new FileWidgetController(widget, file_transfer, stream_interactor);
                    box.append(widget);
                }
                return box;
            }
        }

        public override Gee.List<Plugins.MessageAction>? get_item_actions(Plugins.WidgetType type) {
            Gee.List<Plugins.MessageAction> actions = new ArrayList<Plugins.MessageAction>();
            return actions;
        }
    }

    public class ImageGroupWidget : Box {

        public ImageGroupWidget(Gee.ArrayList<FileTransfer> file_transfers) {

            if (file_transfers.size == 3) {
                Box box = new Box(Orientation.HORIZONTAL, 4) {
                    overflow = Overflow.HIDDEN,
                    halign = Align.START
                };
                box.add_css_class("image-group");

                var picture1 = new FileImageWidget.from_file_transfer(file_transfers[0], 200);
                box.append(picture1);

                Box box1 = new Box(Orientation.VERTICAL, 4);

                var picture2 = new FileImageWidget.from_file_transfer(file_transfers[1], 100);
                box1.append(picture2);
                var picture3 = new FileImageWidget.from_file_transfer(file_transfers[2], 100);
                box1.append(picture3);
                box.append(box1);

                this.append(box);
            } else {
                Box box = new Box(Orientation.VERTICAL, 4) {
                    overflow = Overflow.HIDDEN,
                    halign = Align.START
                };
                box.add_css_class("image-group");

                for (int start = 0; start < file_transfers.size;) {
                    // Preserve the three smaller images in the five-image layout.
                    int columns = file_transfers.size == 5 && start == 2 ? 3 : 2;
                    int size = columns == 3 ? 99 : 150;
                    Box row = new Box(Orientation.HORIZONTAL, 4);
                    for (int column = 0; column < columns && start < file_transfers.size; column++, start++) {
                        row.append(new FileImageWidget.from_file_transfer(file_transfers[start], size));
                    }
                    box.append(row);
                }
                this.append(box);
            }
        }

        private static void dispose_images(Widget widget) {
            if (widget is FileImageWidget) {
                if (widget.parent != null) widget.unparent();
                widget.dispose();
                return;
            }
            Widget? child = widget.get_first_child();
            while (child != null) {
                Widget? next = child.get_next_sibling();
                dispose_images(child);
                child = next;
            }
        }

        public override void dispose() {
            dispose_images(this);
            base.dispose();
        }
    }

    public static bool all_files_images(Gee.ArrayList<FileTransfer> file_transfers) {
        foreach (FileTransfer file_transfer in file_transfers) {
            if (!Dino.Util.is_pixbuf_supported_content_type(file_transfer.content_type)) {
                return false;
            }
        }
        return true;
    }
}
