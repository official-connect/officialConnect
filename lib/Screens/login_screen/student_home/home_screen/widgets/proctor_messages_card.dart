import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../../Classes/sis_proctor_data.dart';

class ProctorMessagesCard extends StatelessWidget {
  final double height;
  final double width;
  final NeumorphicStyle neumorphicStyle;
  final TextStyle buttonTrailing;
  final Object? body;
  final Object? title;
  final TextStyle subtitle;
  final bool isDark;
  final ProctorMessage messageData;
  const ProctorMessagesCard({
    Key? key,
    required this.height,
    required this.width,
    required this.neumorphicStyle,
    required this.buttonTrailing,
    this.body,
    this.title,
    required this.subtitle,
    required this.isDark,
    required this.messageData,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: NeumorphicButton(
        padding: EdgeInsets.only(
          top: height * 0.015,
          bottom: height * 0.015,
          left: width * 0.025,
          right: width * 0.01,
        ),
        style: neumorphicStyle,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            iconColor: const Color(0xffba3237),
            collapsedIconColor: isDark ? Colors.white : Colors.black,
            title: Text(
              messageData.from,
              style: buttonTrailing.copyWith(
                fontSize: (width * 0.06).clamp(18.0, 24.0),
              ),
            ),
            subtitle: Text(messageData.date, style: subtitle),
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.04,
                  vertical: height * 0.02,
                ),
                child: Text(messageData.desc, style: subtitle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
